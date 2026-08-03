#!/usr/bin/env bash
# Turn off, and keep off, every RGB LED in this build -- including the XFX
# Mercury RX 9070 XT's shroud strip, which reaches OpenRGB only by way of the
# motherboard's ARGB header (see README).
#
#   ./install.sh              install udev rule, keep entry and both units
#   ./install.sh --no-i2c     as above, but do not grant standing user access
#                             to the FCH SMBus -- the RAM's RGB then cannot be
#                             changed, only whatever it was last set to sticks
#   ./install.sh --boot       boot-time path: restore anything a SteamOS update
#                             dropped from /etc. Run as root by the system unit
#   ./install.sh --status     report current state and exit
#   ./install.sh --drop-upstream-rules
#                             delete /usr/lib/udev/rules.d/60-openrgb.rules,
#                             which is owned by no package and whose blanket
#                             i2c rule otherwise makes --no-i2c a no-op
#   ./install.sh --uninstall
#
# Nothing lands in /usr, which SteamOS replaces wholesale on every A/B update.
# The udev rule goes in /etc (an overlay: survives reboots unconditionally,
# survives updates only via the atomic-update.conf.d entry) and everything else
# lives in this repo under /home.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UDEV_SRC="$REPO_DIR/udev.rules.d/60-steam-machine-rgb.rules"
UDEV_DEST="/etc/udev/rules.d/60-steam-machine-rgb.rules"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-rgb.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-rgb.conf"
SYS_UNIT_SRC="$REPO_DIR/systemd/steam-machine-rgb.service"
SYS_UNIT_DEST="/etc/systemd/system/steam-machine-rgb.service"
USER_UNIT_SRC="$REPO_DIR/systemd/user/steam-machine-rgb-off.service"
USER_UNIT_DEST="/home/deck/.config/systemd/user/steam-machine-rgb-off.service"
OFF_SCRIPT="$REPO_DIR/bin/rgb-off.sh"

FLATPAK_ID="org.openrgb.OpenRGB"

# The i2c half of the udev rule is what exposes the DDR5 SPD EEPROMs to
# userspace. Marker file rather than re-parsing the rule, so --boot restores
# whatever was chosen at install time instead of silently re-granting it.
I2C_MARKER="/etc/udev/rules.d/.steam-machine-rgb-i2c"

UPSTREAM_RULES="/usr/lib/udev/rules.d/60-openrgb.rules"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A $0 $*)"; }

# --- udev rule ----------------------------------------------------------------
# With --no-i2c, install the rule minus its SMBus stanza -- everything from the
# @I2C-STANZA-BEGIN marker down.
render_rule() {
    if [[ -f "$I2C_MARKER" ]]; then
        cat "$UDEV_SRC"
    else
        grep -q '^#@I2C-STANZA-BEGIN$' "$UDEV_SRC" \
            || die "marker @I2C-STANZA-BEGIN missing from $UDEV_SRC"
        sed '/^# install.sh --no-i2c strips everything below/,$d' "$UDEV_SRC"
        printf '%s\n' \
            '#---------------------------------------------------------------------------#' \
            '# The Kingston FURY DDR5 SMBus stanza was omitted at install time            #' \
            '# (install.sh --no-i2c). The DDR5 SPD EEPROMs share that bus and are always  #' \
            '# host-writable on this platform, so nothing gets standing access to it.     #' \
            '# Re-run install.sh without --no-i2c to restore it.                          #' \
            '#---------------------------------------------------------------------------#'
    fi
}

# Cheap and idempotent, so it is safe on the boot fast path. /etc is an
# overlayfs with its upper layer in /var, writable even when steamos-readonly
# is enabled, so this needs no rootfs unlock.
ensure_etc_config() {
    local restored=0 tmp
    # No `trap ... RETURN` here: bash runs a RETURN trap after the function's
    # locals have been popped, so under `set -u` it dies on $tmp instead of
    # cleaning up -- and it dies *after* the restore has already happened, which
    # is exactly the kind of failure that looks like the self-heal is broken
    # when it isn't. Explicit rm on both paths instead.
    tmp="$(mktemp)"
    render_rule > "$tmp"

    if ! cmp -s "$tmp" "$UDEV_DEST"; then
        install -Dm644 "$tmp" "$UDEV_DEST"
        warn "restored $UDEV_DEST (was missing or modified)"
        restored=1
    fi
    rm -f "$tmp"
    if ! cmp -s "$KEEP_SRC" "$KEEP_DEST"; then
        install -Dm644 "$KEEP_SRC" "$KEEP_DEST"
        warn "restored $KEEP_DEST (was missing or modified)"
    fi

    if [[ $restored -eq 1 ]]; then
        udevadm control --reload-rules 2>/dev/null || warn "udevadm reload failed"
        reapply_tags
    fi
}

# A rules reload does not retag devices that already exist -- it only affects
# the next uevent. Without this, a restored rule does nothing until reboot.
reapply_tags() {
    udevadm trigger --subsystem-match=hidraw --action=change 2>/dev/null || true
    udevadm trigger --subsystem-match=i2c-dev --action=change 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true
}

# --- status helpers -----------------------------------------------------------
# The IT5711 exposes more than one hidraw node (OpenRGB picks whichever answers
# its probe), so report all of them -- checking only the first would hide a
# missing ACL on the one actually in use.
mb_hidraw() {
    local d found=1
    for d in /sys/class/hidraw/hidraw*; do
        if grep -q 'HID_ID=.*:0000048D:00005711' "$d/device/uevent" 2>/dev/null; then
            echo "/dev/$(basename "$d")"; found=0
        fi
    done
    return $found
}

has_acl() { getfacl -p "$1" 2>/dev/null | grep -q '^user:deck:.*r'; }

# Upstream's 158 KB catch-all. Owned by no pacman package on this machine and
# living in /usr, which a SteamOS A/B update replaces wholesale -- but while it
# is there its `KERNEL=="i2c-[0-99]*", TAG+="uaccess"` line grants every i2c bus
# to the seat, which makes --no-i2c a lie. Detected, never silently removed.
upstream_rules_present() { [[ -f "$UPSTREAM_RULES" ]]; }

upstream_grants_i2c() {
    upstream_rules_present && grep -q '^KERNEL=="i2c-\[0-99\]\*", TAG+="uaccess"' "$UPSTREAM_RULES"
}

gpu_i2c_populated() {
    # Any device answering on a bus belonging to the discrete GPU would mean
    # OpenRGB could in principle drive the card directly. Nothing does -- this
    # exists so the claim in the README stays checkable rather than remembered.
    local b name
    for b in /sys/class/i2c-dev/*; do
        name="$(cat "$b/name" 2>/dev/null)"
        [[ "$name" == AMDGPU* ]] || continue
        readlink -f "$b/device" | grep -q '0000:03:00.0' || continue
        return 0
    done
    return 1
}

# --- top level ----------------------------------------------------------------
do_install() {
    local want_i2c=$1
    need_root

    # `flatpak info` as root only sees system installs; OpenRGB is a user one.
    as_deck flatpak info "$FLATPAK_ID" >/dev/null 2>&1 \
        || warn "$FLATPAK_ID is not installed for deck -- flatpak install --user flathub $FLATPAK_ID"

    if [[ $want_i2c -eq 1 ]]; then
        install -Dm644 /dev/null "$I2C_MARKER"
        log "granting user access to the FCH SMBus (RAM RGB reachable)"
        warn "this also exposes the DDR5 SPD EEPROMs -- see hardware/sensors/README.md"
    else
        rm -f "$I2C_MARKER"
        log "SMBus access NOT granted (--no-i2c); RAM RGB will not be detected"
        if upstream_grants_i2c; then
            warn "--no-i2c HAS NO EFFECT while $UPSTREAM_RULES exists:"
            warn "  its blanket KERNEL==\"i2c-[0-99]*\" rule grants every bus anyway."
            warn "  That file is owned by no package and lives in /usr (wiped by the"
            warn "  next OS update regardless). Remove it with: $0 --drop-upstream-rules"
        fi
    fi

    log "installing udev rule -> $UDEV_DEST"
    local tmp; tmp="$(mktemp)"
    render_rule > "$tmp"
    install -Dm644 "$tmp" "$UDEV_DEST"
    rm -f "$tmp"
    install -Dm644 "$KEEP_SRC" "$KEEP_DEST"
    udevadm control --reload-rules || warn "udevadm reload failed"
    reapply_tags

    log "installing system unit -> $SYS_UNIT_DEST"
    install -Dm644 "$SYS_UNIT_SRC" "$SYS_UNIT_DEST"
    systemctl daemon-reload
    systemctl enable steam-machine-rgb.service >/dev/null 2>&1 \
        || warn "could not enable steam-machine-rgb.service"

    log "installing user unit -> $USER_UNIT_DEST"
    install -Dm644 -o deck -g deck "$USER_UNIT_SRC" "$USER_UNIT_DEST"
    chown deck:deck /home/deck/.config/systemd/user /home/deck/.config/systemd 2>/dev/null || true
    as_deck systemctl --user daemon-reload || warn "user daemon-reload failed"
    as_deck systemctl --user enable steam-machine-rgb-off.service >/dev/null 2>&1 \
        || warn "could not enable steam-machine-rgb-off.service"

    log "applying now"
    as_deck "$OFF_SCRIPT" || warn "rgb-off.sh failed -- run it yourself as deck"

    log "done"
    echo
    do_status
}

# systemctl --user and flatpak both need the session's bus; sudo does not carry
# it. Nothing to do if there is no session (e.g. --boot before login).
as_deck() {
    local uid; uid="$(id -u deck)"
    [[ -S "/run/user/$uid/bus" ]] || { warn "no active deck session -- skipping: $*"; return 1; }
    if [[ $EUID -eq 0 ]]; then
        runuser -u deck -- env \
            XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            "$@"
    else
        "$@"
    fi
}

do_boot() {
    need_root --boot
    ensure_etc_config
}

do_status() {
    local hid nodes
    echo -n "udev rule:           "
    if [[ -f "$UDEV_DEST" ]]; then echo "$UDEV_DEST"; else echo "MISSING"; fi
    echo -n "SMBus access:        "
    [[ -f "$I2C_MARKER" ]] && echo "granted (RAM RGB reachable, SPD exposed)" || echo "not granted (--no-i2c)"
    echo -n "upstream rules:      "
    if upstream_grants_i2c; then
        echo "PRESENT at $UPSTREAM_RULES -- grants ALL i2c buses, overrides --no-i2c"
    elif upstream_rules_present; then
        echo "present at $UPSTREAM_RULES (no blanket i2c rule)"
    else
        echo "absent (good)"
    fi
    echo -n "A/B update keep:     "
    [[ -f "$KEEP_DEST" ]] && echo "installed" || echo "MISSING (udev rule lost on next OS update)"
    echo -n "system unit:         "
    systemctl is-enabled steam-machine-rgb.service 2>/dev/null || echo "not installed"
    echo -n "user unit:           "
    as_deck systemctl --user is-enabled steam-machine-rgb-off.service 2>/dev/null || echo "not installed"

    echo
    if nodes="$(mb_hidraw)"; then
        local first=1
        for hid in $nodes; do
            [[ $first -eq 1 ]] && printf '%-20s ' "Gigabyte IT5711:" || printf '%-20s ' ""
            first=0
            printf '%s  (deck access: %s)\n' "$hid" "$(has_acl "$hid" && echo yes || echo NO)"
        done
    else
        echo "Gigabyte IT5711:     NOT FOUND"
    fi
    echo -n "FCH SMBus:           "
    if [[ -e /dev/i2c-2 ]]; then
        printf '/dev/i2c-2  (deck access: %s)\n' "$(has_acl /dev/i2c-2 && echo yes || echo no)"
    else
        echo "absent (acpi_enforce_resources=lax not applied?)"
    fi
    echo -n "GPU i2c controllers: "
    gpu_i2c_populated && echo "buses present" || echo "none"
    echo "  (the RX 9070 XT has no I2C RGB controller at all -- its strip is a"
    echo "   passive 5V ARGB slave driven from a motherboard header. See README.)"

    echo
    echo "OpenRGB sees:"
    as_deck "$OFF_SCRIPT" --list 2>/dev/null | grep -E '^[0-9]+:' || echo "  (could not query)"
}

# Explicit, never part of a normal install: it deletes a file this repo did not
# put there. Safe in the sense that pacman owns nothing in it and /usr is reset
# by the next A/B update anyway -- but it is still someone else's file, and
# removing it drops OpenRGB access for every device except the two named in our
# own rule. Only worth doing to make --no-i2c mean something.
do_drop_upstream() {
    need_root --drop-upstream-rules
    upstream_rules_present || { log "$UPSTREAM_RULES is already absent"; return 0; }
    if pacman -Qo "$UPSTREAM_RULES" >/dev/null 2>&1; then
        die "$UPSTREAM_RULES is owned by a package -- refusing to remove it"
    fi

    local backup="/home/deck/.cache/steam-machine-rgb/60-openrgb.rules.bak"
    install -Dm644 -o deck -g deck "$UPSTREAM_RULES" "$backup"
    log "backed up -> $backup"

    trap relock_rootfs EXIT
    unlock_rootfs
    rm -f "$UPSTREAM_RULES"
    udevadm control --reload-rules || warn "udevadm reload failed"
    reapply_tags
    log "removed $UPSTREAM_RULES"
    warn "OpenRGB now only reaches the devices named in $UDEV_DEST"
}

# Only needed by --drop-upstream-rules; /etc needs no unlock.
RO_WAS_ENABLED=0
unlock_rootfs() {
    if command -v steamos-readonly >/dev/null 2>&1 \
       && [[ "$(steamos-readonly status 2>/dev/null)" == "enabled" ]]; then
        RO_WAS_ENABLED=1
        log "unlocking read-only rootfs"
        steamos-readonly disable
    fi
}
relock_rootfs() {
    if [[ $RO_WAS_ENABLED -eq 1 ]] && command -v steamos-readonly >/dev/null 2>&1; then
        log "restoring read-only rootfs"
        steamos-readonly enable || warn "could not re-enable read-only rootfs"
    fi
}

do_uninstall() {
    need_root --uninstall
    as_deck systemctl --user disable --now steam-machine-rgb-off.service >/dev/null 2>&1 || true
    systemctl disable --now steam-machine-rgb.service >/dev/null 2>&1 || true
    rm -f "$UDEV_DEST" "$KEEP_DEST" "$SYS_UNIT_DEST" "$USER_UNIT_DEST" "$I2C_MARKER"
    systemctl daemon-reload
    as_deck systemctl --user daemon-reload || true
    udevadm control --reload-rules || true
    reapply_tags
    log "uninstalled (LEDs keep whatever Static setting they were last given)"
}

case "${1:-}" in
    ""|--install)  do_install 1 ;;
    --no-i2c)      do_install 0 ;;
    --boot)        do_boot ;;
    --status)      do_status ;;
    --drop-upstream-rules) do_drop_upstream ;;
    --uninstall)   do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
