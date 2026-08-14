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
#   ~/.config/systemd/user/rustdesk-desktop-mode.service
#                                               the Desktop Mode gate (/home)
#   /etc/polkit-1/rules.d/60-steam-machine-rustdesk.rules
#                                               lets the gate start the service
#   /etc/atomic-update.conf.d/steam-machine-rustdesk.conf   keeps the above
#
# DESKTOP MODE ONLY. The service has no [Install] section and never starts at
# boot. RustDesk cannot capture anything in Game Mode -- the gamescope portal
# has no RemoteDesktop interface -- and left running there it spins a shell
# pipeline at ~65 Hz looking for a session it will never find, costing 80% of a
# core and 520 forks/s. See bin/rustdesk-in-desktop-mode and README.md.
#
# /usr is the only writable-ish location that works, and not by choice:
# rustdesk's is_installed() is
#     p.starts_with("/usr") || p.starts_with("/nix/store")
# and --password, --option, --config and --set-id all refuse to run when it is
# false. /opt and /home both fail that test, so the cache-and-restore pattern
# used by hardware/sensors for it87 is the only option that keeps the
# provisioning CLI usable.
set -euo pipefail

# Shared self-elevation (lib/elevate.sh): provides elevate() and need_root().
# Walks up to the repo root so this works at any directory depth.
_lib() {
    local d; d=$(readlink -f "${BASH_SOURCE[0]}"); d=${d%/*}
    while [[ $d != / ]]; do
        [[ -r $d/lib/elevate.sh ]] && { printf '%s\n' "$d/lib/elevate.sh"; return 0; }
        d=${d%/*}
    done
    return 1
}
_l=$(_lib) && source "$_l"


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

POLKIT_RULE="/etc/polkit-1/rules.d/60-steam-machine-rustdesk.rules"
KEEP_CONF="/etc/atomic-update.conf.d/steam-machine-rustdesk.conf"
GATE_CHECK="$REPO_DIR/bin/rustdesk-in-desktop-mode"

# The Desktop-Mode gate. See systemd/user/rustdesk-desktop-mode.service.
USER_UNIT="rustdesk-desktop-mode.service"
USER_UNIT_SRC="$REPO_DIR/systemd/user/$USER_UNIT"
USER_UNIT_DIR="/home/deck/.config/systemd/user"
USER_UNIT_DEST="$USER_UNIT_DIR/$USER_UNIT"
USER_WANTS_DIR="$USER_UNIT_DIR/plasma-workspace.target.wants"
USER_WANTS_LINK="$USER_WANTS_DIR/$USER_UNIT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# need_root() now comes from lib/elevate.sh -- it elevates before dying.

# --- /etc and the user unit ---------------------------------------------------
# repo-relative source -> absolute destination, for everything dropped in /etc.
#
# rustdesk.service is listed even though /etc/systemd/system/*.service is on
# SteamOS's default keep list. Restoring it costs a cmp against one small file,
# and the alternative -- assuming it is there -- is how you end up debugging a
# missing service after a botched update.
declare -A ETC_CONFIG=(
    ["systemd/$UNIT"]="$UNIT_DEST"
    ["polkit-1/rules.d/60-steam-machine-rustdesk.rules"]="$POLKIT_RULE"
    ["atomic-update.conf.d/steam-machine-rustdesk.conf"]="$KEEP_CONF"
)

# Reinstall anything missing or modified. Cheap and idempotent, so it is safe on
# the --boot fast path. Returns 0 if it changed nothing, 1 if it restored
# something -- the caller decides whether that warrants a daemon-reload.
ensure_etc_config() {
    local src changed=0
    for src in "${!ETC_CONFIG[@]}"; do
        if ! cmp -s "$REPO_DIR/$src" "${ETC_CONFIG[$src]}"; then
            install -Dm644 "$REPO_DIR/$src" "${ETC_CONFIG[$src]}"
            warn "restored ${ETC_CONFIG[$src]} (was missing or modified)"
            changed=1
        fi
    done
    return $changed
}

# The user unit lives under /home, which no A/B update touches, so this is
# belt-and-braces rather than the load-bearing persistence mechanism.
#
# The .wants symlink is written by hand rather than via `systemctl --user
# enable`. Running that as root needs the target user's XDG_RUNTIME_DIR and a
# live user manager, neither of which is guaranteed from an ExecStartPre;
# writing the symlink is exactly what enable does, and it works with no manager
# running at all.
ensure_user_unit() {
    local changed=0
    # Explicitly, and before the file: `install -D` creates missing parents
    # owned by whoever is running it, i.e. root. A root-owned
    # ~/.config/systemd/user is not a permission error you would ever guess
    # from the symptom -- the user manager simply ignores the tree.
    install -d -o deck -g deck "$USER_UNIT_DIR" "$USER_WANTS_DIR"
    if ! cmp -s "$USER_UNIT_SRC" "$USER_UNIT_DEST"; then
        install -Dm644 -o deck -g deck "$USER_UNIT_SRC" "$USER_UNIT_DEST"
        warn "restored $USER_UNIT_DEST (was missing or modified)"
        changed=1
    fi
    if [[ ! -L "$USER_WANTS_LINK" ]]; then
        ln -sf "../$USER_UNIT" "$USER_WANTS_LINK"
        chown -h deck:deck "$USER_WANTS_LINK"
        warn "re-enabled $USER_UNIT (wants symlink was missing)"
        changed=1
    fi
    # Best effort: the user manager only needs telling if it is running, and it
    # is not during a Game Mode boot. Failure here is not an error.
    if (( changed )); then
        runuser -u deck -- env XDG_RUNTIME_DIR=/run/user/1000 \
            systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    return 0
}

# True if a Desktop Mode session is active right now. Same check the unit's
# ExecCondition makes -- kept in one place so they cannot drift.
in_desktop_mode() { "$GATE_CHECK"; }
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
    local src
    for src in "${!ETC_CONFIG[@]}"; do
        [[ -f "$REPO_DIR/$src" ]] || die "missing $REPO_DIR/$src"
    done
    [[ -f "$USER_UNIT_SRC" ]] || die "missing $USER_UNIT_SRC"
    [[ -f "$CONF_TMPL"     ]] || die "missing $CONF_TMPL"
    [[ -x "$GATE_CHECK"    ]] || die "$GATE_CHECK is not executable"

    fetch_pkg
    unlock_rootfs
    extract_pkg

    log "installing unit, polkit rule and A/B update keep entry"
    for src in "${!ETC_CONFIG[@]}"; do
        install -Dm644 "$REPO_DIR/$src" "${ETC_CONFIG[$src]}"
    done
    systemctl daemon-reload

    log "installing the Desktop Mode gate ($USER_UNIT)"
    ensure_user_unit

    # An install over the top of the pre-gate version leaves the old
    # multi-user.target.wants symlink behind, which would keep starting the
    # service at boot into Game Mode -- the exact thing this is here to stop.
    # `disable` still removes stale symlinks for a unit with no [Install].
    #
    # Tested for by the symlink, not by `is-enabled`: with no [Install] section
    # that answers `static` and exits 0, so it would report every install as
    # needing this.
    if [[ -e /etc/systemd/system/multi-user.target.wants/$UNIT ]]; then
        log "removing the boot-time start left by the pre-gate version"
        systemctl disable "$UNIT" >/dev/null 2>&1 || true
    fi

    write_config
    apply_firewall

    if in_desktop_mode; then
        log "Desktop Mode is active -- starting $UNIT now"
        systemctl restart "$UNIT" || warn "could not start $UNIT"
    else
        log "Game Mode -- $UNIT stays stopped; it starts on the next switch to Desktop"
        systemctl stop "$UNIT" >/dev/null 2>&1 || true
    fi

    log "done"
    echo
    do_status
    cat <<EOF

NEXT: switch to Desktop Mode (Steam -> Power -> Switch to Desktop). RustDesk
starts with the session and stops when you leave it; it no longer runs in Game
Mode at all. Then set the password --
  sudo $REPO_DIR/install.sh --password
Then connect from another machine on this LAN by IP, not by ID:
  192.168.0.9:$PORT
EOF
}

# Self-heal path, from the unit's ExecStartPre. /usr may have been wiped by an
# update.
#
# Since the Desktop Mode gate this no longer runs at boot -- the unit has no
# [Install] section, so ExecStartPre fires on entry to Desktop Mode instead.
# Everything restored here is needed only when the service is about to run, so
# that is the correct moment; nothing in this subsystem depends on having run
# earlier. The two pieces that DO have to be right before this point are the
# polkit rule (keep-listed) and the user unit (under /home) -- and both are
# checked below anyway, on the off chance something removed them by hand.
#
# Deliberately before any fast-path exit.
do_boot() {
    need_root
    trap relock_rootfs EXIT

    ensure_etc_config || systemctl daemon-reload || true
    ensure_user_unit

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

    # NOT `is-enabled`. The unit has no [Install] section by design, so
    # is-enabled answers `static` forever and says nothing about whether the
    # thing will ever run. What matters is the user-side gate and the current
    # mode, so report those instead.
    echo -n "service:                "
    echo "$(systemctl is-active "$UNIT" 2>/dev/null) (no boot-time start, by design)"

    echo -n "desktop-mode gate:      "
    if [[ -L "$USER_WANTS_LINK" ]] && cmp -s "$USER_UNIT_SRC" "$USER_UNIT_DEST"; then
        echo "enabled ($USER_UNIT wanted by plasma-workspace.target)"
    elif [[ -f "$USER_UNIT_DEST" ]]; then
        echo "PRESENT BUT NOT ENABLED -- re-run the installer"
    else
        echo "MISSING -- RustDesk will never start; re-run the installer"
    fi

    # /etc/polkit-1/rules.d is 0750 root:polkitd, so an unprivileged [[ -f ]] on
    # anything under it is false whether or not the file exists -- the same trap
    # as /root above. Reporting that as MISSING sends you reinstalling a rule
    # that is already in place.
    echo -n "polkit rule:            "
    if [[ ! -r /etc/polkit-1/rules.d ]]; then
        echo "unverifiable as $(id -un) (dir is 0750) -- re-run with sudo"
    elif [[ -f "$POLKIT_RULE" ]] && cmp -s "$REPO_DIR/polkit-1/rules.d/60-steam-machine-rustdesk.rules" "$POLKIT_RULE"; then
        echo "installed"
    else
        echo "MISSING or MODIFIED -- the gate cannot start the service"
    fi

    echo -n "A/B update keep entry:  "
    [[ -f "$KEEP_CONF" ]] && echo "installed" \
        || echo "MISSING (polkit rule will be lost on next OS update)"

    echo -n "current mode:           "
    if in_desktop_mode; then echo "Desktop -- RustDesk is allowed to run"
    else echo "Game -- RustDesk is gated off (ExecCondition would skip a start)"; fi

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
    rm -f "$USER_WANTS_LINK" "$USER_UNIT_DEST"
    runuser -u deck -- env XDG_RUNTIME_DIR=/run/user/1000 \
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    remove_firewall
    unlock_rootfs
    rm -f "$UNIT_DEST" "$POLKIT_RULE" "$KEEP_CONF" "$BIN"
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
