#!/usr/bin/env bash
# RustDesk, LAN-only, unattended, on an immutable rootfs.
#
#   ./install.sh              install (downloads + caches the package if needed)
#   ./install.sh --boot       restore /usr after an A/B update; re-apply firewall
#   ./install.sh --password   set the permanent password (interactive, needs the
#                             service running and a desktop session active)
#   ./install.sh --status
#   ./install.sh --uninstall
#
# Layout, and why:
#   /home/deck/.cache/steam-machine-rustdesk/   the package tarball (persists)
#   /usr/bin/rustdesk -> /usr/share/rustdesk/   the install (WIPED by updates)
#   /etc/systemd/system/rustdesk.service        the unit (keep-listed, persists)
#   /root/.config/rustdesk/RustDesk2.toml       config (/root is an offload
#                                               bind mount, so it persists)
#
# /usr is the only writable-ish location that works, and not by choice:
# rustdesk's is_installed() is
#     p.starts_with("/usr") || p.starts_with("/nix/store")
# and --password, --option, --config and --set-id all refuse to run when it is
# false. /opt and /home both fail that test, so the cache-and-restore pattern
# used by hardware/sensors for it87 is the only option that keeps the
# provisioning CLI usable.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION="1.4.9"
PKG="rustdesk-${VERSION}-0-x86_64.pkg.tar.zst"
URL="https://github.com/rustdesk/rustdesk/releases/download/${VERSION}/${PKG}"
# Recorded from the release asset on 2026-08-03. Verified on every install and
# every boot restore -- the cache lives in a writable home directory, so
# checking it is not paranoia about GitHub but about the local copy.
SHA256="679760e1a1f1b930529069edfaec219afa16b5efe44c1bc593cede0e65576c11"

CACHE_DIR="${RUSTDESK_CACHE:-/home/deck/.cache/steam-machine-rustdesk}"
PKG_PATH="$CACHE_DIR/$PKG"

IFACE="${RUSTDESK_IFACE:-enp9s0}"
PORT="21118"

BIN="/usr/bin/rustdesk"
SHARE="/usr/share/rustdesk"
UNIT="rustdesk.service"
UNIT_SRC="$REPO_DIR/systemd/$UNIT"
UNIT_DEST="/etc/systemd/system/$UNIT"
CONF_TMPL="$REPO_DIR/config/RustDesk2.toml.template"
CONF_DEST="/root/.config/rustdesk/RustDesk2.toml"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"; }

# --- SteamOS read-only rootfs -------------------------------------------------
RO_WAS_ENABLED=0
unlock_rootfs() {
    if command -v steamos-readonly >/dev/null 2>&1 &&
       [[ "$(steamos-readonly status 2>/dev/null)" == "enabled" ]]; then
        RO_WAS_ENABLED=1
        log "unlocking read-only rootfs"
        steamos-readonly disable
    fi
}
relock_rootfs() {
    if [[ $RO_WAS_ENABLED -eq 1 ]]; then
        log "restoring read-only rootfs"
        steamos-readonly enable || warn "could not re-enable read-only rootfs"
    fi
}

# --- LAN subnets --------------------------------------------------------------
# Derived from the live interface, never stored in the repo: this repo is public
# and the IPv6 prefix here is a real routable address, not an RFC1918 one.
#
# Single-host prefixes (/32, /128) are skipped -- SLAAC hands out a /128 for the
# DHCPv6 address, and whitelisting that would allow exactly one host: itself.
# Reads routes as well as addresses, and generalises the two non-routable ranges -- the same derivation system/firewall uses, for the same two reasons.
#
# Addresses alone miss the RA-advertised ULA, which has an on-link route but no address on this interface. That is not theoretical: it left RustDesk over the ULA being dropped by RustDesk's own rule, with no error anywhere.
#
# And pinning whatever /64 happens to be live is a bug this network keeps proving. pfSense has renumbered the ULA twice now (fd50:fdf7:233::/64 -> fde4:ff5:dc44:476e::/64 -> back again), silently invalidating the pinned rule each time. fc00::/7 and fe80::/10 are not routable on the internet, so allowing each whole range costs nothing. The GUA cannot be generalised -- allowing 2000::/3 would defeat the point -- so it stays pinned and goes stale on re-delegation, which the ExecStartPre re-derivation on every service start is what recovers from.
lan_cidrs() {
    {
        ip -o addr show "$IFACE" 2>/dev/null | awk '{print $4}'
        ip -o -6 route show dev "$IFACE" 2>/dev/null | awk '{print $1}'
        ip -o -4 route show dev "$IFACE" 2>/dev/null | awk '{print $1}'
    } | python3 -c '
import sys, ipaddress
seen = []
ula = ipaddress.ip_network("fc00::/7")
ll = ipaddress.ip_network("fe80::/10")
for line in sys.stdin:
    line = line.strip()
    if not line or line == "default":
        continue
    try:
        net = ipaddress.ip_interface(line).network
    except ValueError:
        continue
    # /128 and /32 are single hosts -- SLAAC hands one out for the DHCPv6
    # address, and allowing it would permit exactly one host: this one.
    if net.num_addresses == 1 or net.network_address.is_loopback:
        continue
    if net.version == 6:
        if net.subnet_of(ula):
            cidr = "fc00::/7"
        elif net.subnet_of(ll):
            cidr = "fe80::/10"
        else:
            cidr = str(net)
    else:
        cidr = str(net)
    if cidr not in seen:
        seen.append(cidr)
print(",".join(seen))
'
}

# --- firewall -----------------------------------------------------------------
# The `public` zone on this machine allows 1024-65535/tcp and /udp wholesale
# (SteamOS ships it that way for Steam), and the box has a globally routable
# IPv6 address. So the direct-access port is NOT LAN-only by default -- it is
# reachable from anywhere the router will forward, with only RustDesk's own
# whitelist in the way.
#
# Runtime rules, not --permanent: /etc/firewalld is not on SteamOS's keep list,
# and allowlisting the zone file would shadow every future upstream version of
# it. Re-applied from ExecStartPre on every service start instead. The gap that
# leaves -- a `firewall-cmd --reload` drops these until the next restart -- is
# covered by the RustDesk whitelist, which is enforced in-process.
apply_firewall() {
    command -v firewall-cmd >/dev/null 2>&1 || { warn "no firewalld; skipping"; return 0; }
    systemctl is-active --quiet firewalld 2>/dev/null || { warn "firewalld inactive; skipping"; return 0; }

    local zone cidrs c
    zone="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
    cidrs="$(lan_cidrs)"
    [[ -n "$cidrs" ]] || { warn "could not derive LAN subnets; NOT touching the firewall"; return 0; }

    # Reconcile, do not just add. Without this the accepts only ever accumulate:
    # every prefix change leaves the previous CIDR's rule behind forever. That
    # is not hypothetical -- generalising fe80::/64 to fe80::/10 left the old
    # /64 rule sitting in the zone. Harmless in that instance because one is a
    # subset of the other, but a re-delegated GUA would leave a stale accept for
    # a prefix that now belongs to somebody else. Removing first is safe: this
    # only ever matches rules carrying port="$PORT".
    remove_firewall

    # Order matters. A negative priority sorts the accepts ahead of the drop;
    # without it firewalld's default ordering would let the drop win for
    # everyone. Only port 21118 is ever referenced -- nothing here can affect
    # SSH, which is a separate `ssh` service entry in the same zone.
    for c in ${cidrs//,/ }; do
        local fam="ipv4"; [[ "$c" == *:* ]] && fam="ipv6"
        firewall-cmd --quiet --zone="$zone" --add-rich-rule \
            "rule priority=\"-100\" family=\"$fam\" source address=\"$c\" port port=\"$PORT\" protocol=\"tcp\" accept" \
            2>/dev/null || warn "could not add accept rule for $c"
    done
    firewall-cmd --quiet --zone="$zone" --add-rich-rule \
        "rule priority=\"0\" port port=\"$PORT\" protocol=\"tcp\" drop" \
        2>/dev/null || warn "could not add the default drop rule"

    log "firewall: $PORT/tcp restricted to $cidrs (runtime rules, zone $zone)"
}

# Matching is done in bash, not by piping into rg. Under `set -o pipefail` a
# grep/rg that matches nothing exits 1, fails the pipeline, and `set -e` then
# kills the script -- on exactly the case where there is nothing to remove.
remove_firewall() {
    command -v firewall-cmd >/dev/null 2>&1 || return 0
    local zone r rules
    zone="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
    rules="$(firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null || true)"
    [[ -n "$rules" ]] || return 0
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        [[ "$r" == *"port=\"$PORT\""* ]] || continue
        firewall-cmd --quiet --zone="$zone" --remove-rich-rule "$r" || true
    done <<< "$rules"
}

# --- package ------------------------------------------------------------------
verify_pkg() { [[ -f "$PKG_PATH" ]] && echo "$SHA256  $PKG_PATH" | sha256sum -c --status; }

fetch_pkg() {
    if verify_pkg; then log "using cached $PKG"; return 0; fi
    [[ -f "$PKG_PATH" ]] && warn "cached package failed checksum -- refetching"
    mkdir -p "$CACHE_DIR"
    log "downloading $PKG"
    curl -fsSL -o "$PKG_PATH.part" "$URL" || die "download failed"
    mv "$PKG_PATH.part" "$PKG_PATH"
    verify_pkg || die "checksum mismatch on $PKG -- refusing to install"
    chown -R deck:deck "$CACHE_DIR" 2>/dev/null || true
    log "cached and verified $PKG_PATH"
}

installed_ok() { [[ -x "$SHARE/rustdesk" && -e "$BIN" ]]; }

# Extract straight out of the tarball rather than going through pacman. pacman
# would record rustdesk in a database that lives outside the A/B image, so after
# an update it would claim the package is installed while /usr had been wiped --
# and `pacman -U` on SteamOS additionally needs the keyring bootstrapped.
extract_pkg() {
    log "installing to /usr from $PKG"
    tar --zstd -xf "$PKG_PATH" -C / --exclude='.BUILDINFO' --exclude='.INSTALL' \
        --exclude='.MTREE' --exclude='.PKGINFO' \
        || die "extraction failed"
    [[ -x "$SHARE/rustdesk" ]] || die "extraction produced no $SHARE/rustdesk"

    # The package ships its .desktop files to /usr/share/rustdesk/files/ and
    # relies on .INSTALL's post_install() to copy them into
    # /usr/share/applications/. We exclude .INSTALL on purpose -- it also
    # overwrites our unit with upstream's and runs systemctl enable/start -- but
    # the desktop entries still have to be placed by hand, or RustDesk never
    # appears in the Desktop Mode application menu at all.
    #
    # That is not cosmetic. With no menu entry the obvious move is to install the
    # Flatpak instead, which lands at /app, fails rustdesk's own is_installed()
    # check, keeps a separate config and ID, and fights this install for 21118.
    local d
    for d in rustdesk.desktop rustdesk-link.desktop; do
        [[ -f "$SHARE/files/$d" ]] || continue
        install -Dm644 "$SHARE/files/$d" "/usr/share/applications/$d"
    done
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
}

# --- config -------------------------------------------------------------------
# Merge our [options] into an existing RustDesk2.toml rather than overwriting
# it, so top-level state RustDesk owns (rendezvous_server, nat_type, serial,
# trusted_devices) and options it sets for itself (local-ip-addr, av1-test)
# survive.
merge_options() {
    local dest="$1" cidrs="$2" tmpl="$3"
    python3 - "$dest" "$cidrs" "$tmpl" <<'PY'
import re, sys, pathlib
dest, cidrs, tmpl = sys.argv[1], sys.argv[2], sys.argv[3]

wanted = {}
for line in pathlib.Path(tmpl).read_text().splitlines():
    m = re.match(r'^\s*([A-Za-z0-9._-]+)\s*=\s*"(.*)"\s*$', line)
    if m:
        wanted[m.group(1)] = m.group(2).replace("@LAN_CIDRS@", cidrs)

head, opts = [], {}
if pathlib.Path(dest).exists():
    in_opts = False
    for line in pathlib.Path(dest).read_text().splitlines():
        s = line.strip()
        if s.startswith("["):
            in_opts = (s == "[options]")
            if not in_opts:
                head.append(line)
            continue
        m = re.match(r"^\s*([A-Za-z0-9._-]+)\s*=\s*(.*)$", line)
        if in_opts and m:
            opts[m.group(1)] = m.group(2)
        elif not in_opts:
            head.append(line)

for k, v in wanted.items():
    opts[k] = f"'{v}'"

out = "\n".join(l for l in head if l.strip()) + "\n\n[options]\n"
out += "".join(f"{k} = {v}\n" for k, v in sorted(opts.items()))
pathlib.Path(dest).write_text(out)
PY
}

# Written to BOTH root's and the desktop user's config, deliberately.
#
# rustdesk --service spawns --server as `deck`, and a 0.3s loop pushes
# user-side config UP to root. So a pre-existing deck config -- and one exists
# the moment anything has ever run `rustdesk` as that user, even just
# `--get-id` -- silently overwrites whatever we put in /root. Writing root's
# copy alone is not enough; that failure mode is what left direct-server unset
# and nothing listening on 21118.
#
# The service must be stopped around this, or the sync loop races the write.
# Bounded wait around lan_cidrs. Ordering the unit after network-online.target
# fixes the common case, but that target can be reached before IPv6 RA has been
# answered, and the whitelist needs the v6 prefixes as much as the v4 one. Polls
# rather than sleeping a fixed amount so a warm boot costs nothing.
#
# Returns empty on timeout and lets the caller decide -- this must never hang a
# boot forever waiting for a network that is not coming.
lan_cidrs_wait() {
    local deadline=$(( SECONDS + ${LAN_WAIT_SECS:-45} )) cidrs
    while :; do
        cidrs="$(lan_cidrs)"
        [[ -n "$cidrs" ]] && { echo "$cidrs"; return 0; }
        [[ $SECONDS -ge $deadline ]] && return 0
        sleep 2
    done
}

write_config() {
    local cidrs; cidrs="$(lan_cidrs_wait)"
    [[ -n "$cidrs" ]] || die "could not derive LAN subnets for the whitelist after ${LAN_WAIT_SECS:-45}s -- is the interface up?"

    local was_active=0
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        was_active=1
        log "stopping $UNIT so the config sync loop cannot race the write"
        systemctl stop "$UNIT"
        # --service leaves --server children behind; the sync loop lives there.
        pkill -f 'rustdesk --server' 2>/dev/null || true
        sleep 1
    fi

    log "writing config (whitelist: $cidrs)"
    install -d -m700 "$(dirname "$CONF_DEST")"
    merge_options "$CONF_DEST" "$cidrs" "$CONF_TMPL"
    chmod 600 "$CONF_DEST"

    local user_conf="/home/deck/.config/rustdesk/RustDesk2.toml"
    install -d -o deck -g deck -m700 "$(dirname "$user_conf")"
    merge_options "$user_conf" "$cidrs" "$CONF_TMPL"
    chown deck:deck "$user_conf"; chmod 600 "$user_conf"

    [[ $was_active -eq 1 ]] && systemctl start "$UNIT" || true
    return 0
}

do_password() {
    need_root
    installed_ok || die "rustdesk is not installed"
    systemctl is-active --quiet "$UNIT" || die "$UNIT must be running first"
    cat <<'EOF'
Setting the permanent password.

This goes through RustDesk's IPC socket, so it needs the --server child to be
alive -- which means a desktop session must be active. It cannot be written
into RustDesk.toml by hand: the stored blob is
    "01" + secretbox(  "00" + base64(SHA256(password + salt))  )
sealed with a key derived from this machine's UUID, so it is not portable and
not computable offline.
EOF
    read -rsp "New RustDesk password: " pw; echo
    [[ -n "$pw" ]] || die "empty password"
    "$BIN" --password "$pw" || die "rustdesk --password failed"
    log "password set"
}

do_install() {
    need_root
    trap relock_rootfs EXIT
    [[ -f "$UNIT_SRC"  ]] || die "missing $UNIT_SRC"
    [[ -f "$CONF_TMPL" ]] || die "missing $CONF_TMPL"

    fetch_pkg
    unlock_rootfs
    extract_pkg

    log "installing $UNIT_DEST"
    install -Dm644 "$UNIT_SRC" "$UNIT_DEST"
    systemctl daemon-reload

    write_config
    apply_firewall

    log "enabling and starting $UNIT"
    systemctl enable --now "$UNIT" || warn "could not start $UNIT"

    log "done"
    echo
    do_status
    cat <<EOF

NEXT: set the password, with a desktop session active on the TV --
  sudo $REPO_DIR/install.sh --password
Then connect from another machine on this LAN by IP, not by ID:
  192.168.0.9:$PORT
EOF
}

# Boot path, from the unit's ExecStartPre. /usr may have been wiped by an update.
do_boot() {
    need_root
    trap relock_rootfs EXIT

    if ! installed_ok; then
        warn "/usr/share/rustdesk is missing -- restoring from cache"
        fetch_pkg
        unlock_rootfs
        extract_pkg
    fi
    write_config
    apply_firewall
}

do_status() {
    echo -n "binary:                 "
    if installed_ok; then echo "$($SHARE/rustdesk --version 2>/dev/null || echo '?') at $SHARE"
    else echo "NOT installed"; fi

    echo -n "desktop entry:          "
    if [[ -f /usr/share/applications/rustdesk.desktop ]]; then
        echo "installed (appears in the Desktop Mode menu)"
    else
        echo "MISSING -- RustDesk will not appear in the application menu"
    fi

    # A Flatpak alongside this install is worth shouting about. It is the natural
    # thing to reach for when the menu entry is missing, and it silently competes:
    # /app fails rustdesk's is_installed(), so --password and friends break, it
    # keeps its own config and ID under ~/.var/app, and it wants port 21118 too.
    echo -n "conflicting flatpak:    "
    if flatpak list --app 2>/dev/null | grep -qi 'com\.rustdesk\.RustDesk'; then
        echo "PRESENT -- remove it: flatpak uninstall com.rustdesk.RustDesk"
    else
        echo "none"
    fi

    echo -n "cached package:         "
    verify_pkg && echo "$PKG (checksum OK)" || echo "MISSING or CORRUPT"

    echo -n "service:                "
    if systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
        echo "enabled, $(systemctl is-active "$UNIT" 2>/dev/null)"
    else echo "NOT enabled"; fi

    # /root is 0700, so an unprivileged [[ -f ]] on anything under it is false
    # whether or not the file exists. Reporting that as MISSING sends you
    # reinstalling something already in place -- the same trap as the polkit
    # rule in hardware/sleep and the sshd -t check in system/ssh.
    echo -n "config:                 "
    if [[ ! -r /root ]]; then
        echo "unverifiable as $(id -un) (/root is 0700) -- re-run with sudo"
    elif [[ -f "$CONF_DEST" ]]; then
        echo "$CONF_DEST"
        printf '  %s\n' "$(grep -E '^(direct-server|direct-access-port|verification-method|whitelist)' "$CONF_DEST" | tr '\n' ' ')"
    else
        echo "MISSING"
    fi

    echo -n "password set:           "
    if [[ ! -r /root ]]; then
        echo "unverifiable as $(id -un) -- re-run with sudo"
    elif [[ -f /root/.config/rustdesk/RustDesk.toml ]]; then
        grep -q "^password = '.\+'" /root/.config/rustdesk/RustDesk.toml \
            && echo "yes" || echo "NO -- run --password"
    else
        echo "NO -- run --password"
    fi

    echo -n "listening on $PORT:     "
    ss -tln 2>/dev/null | rg -q ":$PORT " && echo "yes" || echo "no"

    echo -n "seat0 session type:     "
    printf '%s' "$(loginctl show-session "$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null)" -p Type --value 2>/dev/null)"
    echo "   (wayland => portal/PipeWire capture; x11/tty => X11 capture, black under gamescope)"

    echo "firewall rich rules for $PORT:"
    firewall-cmd --list-rich-rules 2>/dev/null | rg -F "port=\"$PORT\"" | sed 's/^/  /' || echo "  (none)"
}

do_uninstall() {
    need_root
    trap relock_rootfs EXIT
    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    remove_firewall
    unlock_rootfs
    rm -f "$UNIT_DEST" "$BIN"
    rm -rf "$SHARE"
    systemctl daemon-reload
    warn "removed. Config left at /root/.config/rustdesk and cache at $CACHE_DIR"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --boot)       do_boot ;;
    --password)   do_password ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
