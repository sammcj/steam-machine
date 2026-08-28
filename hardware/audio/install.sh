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

    # Link speed only means something once you know which controller it is on:
    # 12 Mbps on 11:00.4 is a clean full-speed negotiation, 12 Mbps on 0f:00.0 is
    # the retry after a failed high-speed attempt. See README.md. Globbing every
    # bus, not just bus 1 -- the intended rear port enumerates on bus 5.
    local d speed ctrl card range dongle="" found=0
    for d in /sys/bus/usb/devices/*/; do
        [[ -f $d/product ]] || continue
        grep -qi stealth "$d/product" 2>/dev/null || continue
        found=1
        dongle="$d"
        speed="$(cat "$d/speed" 2>/dev/null)"
        # Last PCI address on the sysfs path is the xHCI controller.
        ctrl="$(readlink -f "$d" | grep -o '0000:[0-9a-f]\{2\}:[0-9a-f]\{2\}\.[0-9]' | tail -1)"
        case "$ctrl" in
            0000:11:00.4)
                printf 'usb:      %s at %s Mbps on %s (rear, isolated -- correct)\n' \
                    "$(basename "$d")" "$speed" "$ctrl" ;;
            0000:0f:00.0)
                printf 'usb:      %s at %s Mbps on %s -- SHARED with the input devices;\n' \
                    "$(basename "$d")" "$speed" "$ctrl"
                printf '          move it to a rear port on 11:00.4 (see README.md)\n' ;;
            *)
                printf 'usb:      %s at %s Mbps on %s (unexpected controller)\n' \
                    "$(basename "$d")" "$speed" "$ctrl" ;;
        esac
    done

    if [[ $found -eq 0 ]]; then
        printf 'usb:      dongle not on the bus -- if just plugged in, wait 3 min before\n'
        printf '          re-seating; recovery takes ~2m45s (README.md)\n'
        return 0
    fi

    # A one-step volume range means control transfers are still timing out, i.e.
    # the device is mid-recovery rather than settled. Healthy is 0 - 74.
    card="$(basename "$(ls -d /sys/bus/usb/devices/*/*/sound/card* 2>/dev/null \
        | grep -F "$(basename "$dongle")/" | head -1)" 2>/dev/null || true)"
    card="${card#card}"
    if [[ -n $card ]]; then
        range="$(amixer -c "$card" 2>/dev/null | sed -n 's/.*Limits: Playback \([0-9]* - [0-9]*\).*/\1/p' | head -1)"
        if [[ -z $range ]]; then
            printf 'mixer:    no PCM playback control found on card %s\n' "$card"
        elif [[ $range == "0 - 74" ]]; then
            printf 'mixer:    card %s range %s (healthy)\n' "$card" "$range"
        else
            printf 'mixer:    card %s range %s -- collapsed, device still recovering\n' "$card" "$range"
        fi
    fi
}

case "${1:-}" in
    ''|--install) do_install ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *)            die "unknown option: $1" ;;
esac
