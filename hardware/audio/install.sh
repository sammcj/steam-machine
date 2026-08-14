#!/usr/bin/env bash
# USB headset audio settings for this machine. See ./README.md.
#
#   ./install.sh              install the WirePlumber drop-in
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall
#
# There is no --boot. Everything here lives in /home/deck/.config, which is on
# the home partition and is not touched by a SteamOS A/B update -- so unlike
# the subsystems that write to /etc or /usr, this one cannot be lost and needs
# neither an atomic-update keep entry nor a boot self-heal.
#
# What it installs is one drop-in that stops WirePlumber suspending the Turtle
# Beach USB sink after 5 s idle. The full reasoning and the A/B measurement are
# in README.md; the short version is that suspending closes the ALSA device,
# which stops the USB isochronous stream, which makes the 2.4 GHz dongle
# re-sync -- audible as a dropout every time a game leaves the sink idle.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_USER="deck"
TARGET_HOME="/home/$TARGET_USER"
CONF_DIR="$TARGET_HOME/.config/wireplumber/wireplumber.conf.d"
CONF_NAME="51-turtle-beach-no-suspend.conf"
SRC="$REPO_DIR/wireplumber/$CONF_NAME"
DST="$CONF_DIR/$CONF_NAME"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Runs as deck directly, or as root via the top-level install.sh. In the root
# case every write has to end up owned by deck or WirePlumber -- a user service
# -- silently cannot read its own config.
as_user() {
    if [[ $EUID -eq 0 ]]; then
        runuser -u "$TARGET_USER" -- "$@"
    else
        "$@"
    fi
}

do_install() {
    [[ -f $SRC ]] || die "missing $SRC"
    as_user mkdir -p "$CONF_DIR"
    if cmp -s "$SRC" "$DST"; then
        log "$CONF_NAME already current"
    else
        as_user cp "$SRC" "$DST"
        log "installed $DST"
        warn "restart WirePlumber to apply: systemctl --user restart wireplumber"
    fi
}

do_uninstall() {
    [[ -f $DST ]] || { log "not installed"; return 0; }
    as_user rm -f "$DST"
    log "removed $DST"
    warn "restart WirePlumber to apply: systemctl --user restart wireplumber"
}

# Reports the file AND the value WirePlumber actually resolved. Those differ
# whenever the file is installed but the service has not been restarted, which
# is the normal state right after an install and the one worth catching.
do_status() {
    if [[ -f $DST ]]; then
        if cmp -s "$SRC" "$DST"; then
            printf 'config:   installed (matches repo)\n'
        else
            printf 'config:   installed but DIFFERS from repo\n'
        fi
    else
        printf 'config:   not installed\n'
    fi

    local live
    live="$(as_user pw-dump 2>/dev/null | python3 -c '
import json, sys
try:
    objs = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for o in objs:
    p = (o.get("info") or {}).get("props") or {}
    n = p.get("node.name", "")
    if n.startswith("alsa_output.usb-Turtle_Beach"):
        print(p.get("session.suspend-timeout-seconds", "NOT SET"))
        break
' 2>/dev/null || true)"

    if [[ -z $live ]]; then
        printf 'live:     headset sink not present (dongle unplugged, or PipeWire down)\n'
    elif [[ $live == 0 ]]; then
        printf 'live:     suspend-timeout = 0 (suspend disabled)\n'
    else
        printf 'live:     suspend-timeout = %s -- NOT applied, restart wireplumber\n' "$live"
    fi

    # The dongle is a high-speed device. Full speed means enumeration failed and
    # the USB core retried at a lower speed -- see README.md.
    local d speed
    for d in /sys/bus/usb/devices/1-*/; do
        [[ -f $d/product ]] || continue
        grep -qi stealth "$d/product" 2>/dev/null || continue
        speed="$(cat "$d/speed" 2>/dev/null)"
        if [[ $speed == 480 ]]; then
            printf 'usb:      %s at %s Mbps (high speed, correct)\n' "$(basename "$d")" "$speed"
        else
            printf 'usb:      %s at %s Mbps -- expected 480, re-seat the dongle\n' "$(basename "$d")" "$speed"
        fi
    done
}

case "${1:-}" in
    ''|--install) do_install ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *)            die "unknown option: $1" ;;
esac
