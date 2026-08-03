#!/usr/bin/env bash
# Force every RGB controller on this machine to solid black.
#
#   ./rgb-off.sh            apply now, once
#   ./rgb-off.sh --boot     as above, but wait for the devices to appear first
#                           (used by the systemd user unit at login)
#   ./rgb-off.sh --colour RRGGBB
#                           use a colour other than black, for testing that a
#                           strip is actually being addressed
#   ./rgb-off.sh --list     show what OpenRGB currently detects
#
# Runs as `deck`, not root: OpenRGB is a user Flatpak and the udev rules grant
# access through the seat's uaccess ACL, which only exists for the logged-in
# user. Running this under sudo would talk to the same hardware but is not how
# it is wired up at boot, so keep the two paths identical.
set -euo pipefail

OPENRGB=(flatpak run org.openrgb.OpenRGB --noautoconnect)

# Substring matches (OpenRGB does its own >=3-character search), so these stay
# correct if a firmware revision changes the reported name.
MB_DEVICE="B850M FORCE"
RAM_DEVICE="Kingston Fury DDR5"

# How many LEDs to address on each Gigabyte ARGB header.
#
# The GPU shroud strip is a dumb 5V ARGB slave: it reports nothing back, so
# there is no way to read its length -- it has to be told. Overshooting is
# harmless (the surplus bytes clock off the end of the chain and are dropped),
# undershooting leaves the tail of the strip lit, so this is deliberately
# generous. Gigabyte's own limit for these headers is 256.
#
# All three headers are sized and blanked because which one the XFX sync cable
# ends up in is a decision made with the side panel off, not here.
ARGB_LEDS="${ARGB_LEDS:-64}"
ARGB_ZONES=(0 1 2)   # ARGB_V2_1, ARGB_V2_2, ARGB_V2_3 -- zone 3 is LED_C (12V)

COLOUR="000000"
WAIT=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# OpenRGB prints an HTML warning block to stdout on every invocation --
# "The OpenRGB udev rules are not installed" -- because the Flatpak sandbox has
# its own /usr and cannot see the host's rules files. It is a false positive
# whenever detection below actually succeeds. Strip it so real output is legible.
openrgb() { "${OPENRGB[@]}" "$@" 2>&1 | grep -v '^<' || true; }

detected() { openrgb --list-devices 2>/dev/null | grep -qi -- "$1"; }

# The uaccess ACL is applied when the seat session activates, which races the
# systemd user unit at login. Retry rather than fail the boot.
wait_for_device() {
    local name="$1" tries=0
    until detected "$name"; do
        tries=$((tries + 1))
        if [[ $tries -ge 12 ]]; then
            warn "'$name' still not detected after 60s"
            return 1
        fi
        sleep 5
    done
    [[ $tries -gt 0 ]] && log "'$name' appeared after $((tries * 5))s"
    return 0
}

blank_motherboard() {
    local z
    log "sizing ARGB headers to $ARGB_LEDS LEDs"
    # Sizes first, in their own pass. `-z` scopes everything that follows it to
    # that one zone, so a resize and a device-wide colour cannot be combined in
    # a single invocation without the colour landing on only the last zone.
    for z in "${ARGB_ZONES[@]}"; do
        openrgb -d "$MB_DEVICE" -z "$z" -sz "$ARGB_LEDS" >/dev/null
    done

    # No -z: applies to all four zones, including the 12V LED_C header.
    #
    # Static, not Direct. Direct mode is host-driven -- the controller holds
    # the last frame it was sent and nothing more, so it is at the mercy of
    # whatever writes next. Static is committed to the IT5711 and survives
    # both OpenRGB exiting and a power cycle, which is what makes this a
    # set-and-forget rather than a daemon.
    log "setting $MB_DEVICE to #$COLOUR (static)"
    openrgb -d "$MB_DEVICE" -m static -c "$COLOUR" >/dev/null
}

blank_ram() {
    if ! detected "$RAM_DEVICE"; then
        # Expected when install.sh --no-i2c was used: no /dev/i2c access, so
        # the SMBus controllers are invisible. The RAM keeps whatever Static
        # setting it was last given.
        log "$RAM_DEVICE not detected (no SMBus access?) -- skipping"
        return 0
    fi
    log "setting $RAM_DEVICE to #$COLOUR (static)"
    openrgb -d "$RAM_DEVICE" -m static -c "$COLOUR" >/dev/null
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --boot)    WAIT=1; shift ;;
        --colour|--color)
                   COLOUR="${2#\#}"; shift 2
                   [[ "$COLOUR" =~ ^[0-9A-Fa-f]{6}$ ]] || die "colour must be RRGGBB" ;;
        --list)    openrgb --list-devices; exit 0 ;;
        *)         die "unknown option: $1" ;;
    esac
done

command -v flatpak >/dev/null 2>&1 || die "flatpak not found"
flatpak info org.openrgb.OpenRGB >/dev/null 2>&1 \
    || die "org.openrgb.OpenRGB is not installed (flatpak install flathub org.openrgb.OpenRGB)"

if [[ $WAIT -eq 1 ]]; then
    wait_for_device "$MB_DEVICE" || die "motherboard controller never appeared"
fi

blank_motherboard
blank_ram
log "done"
