#!/usr/bin/env bash
# Test 4K120 over the UGREEN active DP 1.4 -> HDMI 2.1 cable.
#
# Every modeset here is guarded by a background timer that restores a known-good
# mode unless we confirm the picture survived. The TV is this machine's only
# console: an unsyncable mode locks you out with no way to type the fix.
#
# Usage:  ./test-dp-hdmi-4k120.sh
set -uo pipefail

SAFE_REVERT_SECS=20

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- find the PCON
say "Connector status"
for c in /sys/class/drm/card0-DP-* /sys/class/drm/card0-HDMI-A-1; do
    printf '  %-22s %s\n' "$(basename "$c")" "$(cat "$c/status" 2>/dev/null)"
done

OUT=$(kscreen-doctor -o 2>&1 | grep -oP 'Output: \d+ \K(DP-\d+)' | head -1)
if [[ -z $OUT ]]; then
    echo "No DisplayPort output active. Plug the DP end into the GPU and the HDMI end into the TV."
    exit 1
fi
say "Driving via $OUT"

# ------------------------------------------------------- did it negotiate FRL?
say "PCON / FRL negotiation (dmesg)"
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A dmesg | grep -iE 'pcon|frl|dsc|link training' | tail -15 \
    || echo "  (nothing logged)"

say "DSC state"
DSCF=$(ls -d /sys/kernel/debug/dri/0/"$OUT"/dsc_* 2>/dev/null)
if [[ -n $DSCF ]]; then
    for f in $DSCF; do
        printf '  %-24s %s\n' "$(basename "$f")" \
            "$(SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A cat "$f" 2>/dev/null | tr '\n' ' ')"
    done
else
    echo "  (no dsc_* debugfs entries)"
fi

# --------------------------------------------------------------- offered modes
say "4K modes offered"
kscreen-doctor -o 2>&1 | grep -oP '3840x2160@\d+' | sort -u -t@ -k2 -n | sed 's/^/  /'

IDX120=$(kscreen-doctor -o 2>&1 | grep -oP "\d+(?=:3840x2160@120)" | head -1)
IDX60=$(kscreen-doctor  -o 2>&1 | grep -oP "\d+(?=:3840x2160@60)"  | head -1)

if [[ -z $IDX120 ]]; then
    echo
    echo "4K120 is NOT being offered. The adapter is not negotiating HDMI 2.1 FRL."
    echo "Check: DP end in the GPU (these cables are unidirectional), and that the"
    echo "TV's HDMI port has 'HDMI Deep Colour'/'HDMI Ultra HD Deep Colour' enabled"
    echo "in Settings > General > External Devices. The C9 needs that per-port."
    exit 1
fi

# ------------------------------------------------- modeset, with a dead-man switch
say "Setting 4K120 (auto-reverts to 4K60 in ${SAFE_REVERT_SECS}s unless confirmed)"
REVERT_FLAG=$(mktemp)
(
    sleep "$SAFE_REVERT_SECS"
    [[ -f $REVERT_FLAG ]] && kscreen-doctor "output.$OUT.mode.$IDX60" >/dev/null 2>&1
) &
REVERT_PID=$!

kscreen-doctor "output.$OUT.mode.$IDX120" >/dev/null 2>&1
sleep 3

echo
read -r -p "Can you see this clearly at 120 Hz? [y/N] " ANS
if [[ ${ANS,,} == y ]]; then
    rm -f "$REVERT_FLAG"; kill "$REVERT_PID" 2>/dev/null
    say "Keeping 4K120"
    kscreen-doctor -o 2>&1 | grep -oP '[0-9x]+@[0-9]+\*'
    kscreen-doctor -o 2>&1 | grep -iE 'HDR:|Wide Color|Vrr:|Color resolution' | sed 's/^\s*/  /'
    echo
    echo "Confirm on the TV itself: press the green (i) / Home > input info panel."
    echo "It should report 3840x2160 120Hz, and HDR if a HDR title is running."
else
    say "Reverting to 4K60"
    rm -f "$REVERT_FLAG"; kill "$REVERT_PID" 2>/dev/null
    kscreen-doctor "output.$OUT.mode.$IDX60" >/dev/null 2>&1
fi
