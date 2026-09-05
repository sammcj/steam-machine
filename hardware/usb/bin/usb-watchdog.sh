#!/usr/bin/env bash
# Watch for a broken xHCI controller and recover it. See ../README.md.
#
# Run by steam-machine-usb-watchdog.service; not normally run by hand.
# Environment (set in the unit, so systemctl edit is enough to change them):
#
#   USB_WATCHDOG_INTERVAL   seconds between checks          (default 5)
#   USB_WATCHDOG_MAX        recoveries before giving up     (default 5)
#   USB_WATCHDOG_WINDOW     ...within this many seconds     (default 900)
#
# WHY A LOOP AND NOT A TIMER
#
# Two reasons, both about SteamOS rather than taste. /etc/systemd/system/*.timer
# is NOT on the default atomic-update keep list while *.service is, so a timer
# needs its own keep entry and silently stops working after an A/B update if
# that entry was missing when the update ran. And a 5 s timer means a unit
# start every 5 s forever, where this is one sleeping process reading four
# sysfs files.
#
# WHAT COUNTS AS BROKEN
#
# Not runtime_status=error. That flag only means the controller can never
# runtime-suspend again, which is harmless once udev.rules.d/ has pinned
# power/control=on -- and on 2026-09-05 an earlier version of this watchdog
# treated it as a fault and did a disruptive remove/rescan on a bus that had
# all ten of its devices present and working. The test now lives in
# usb-reset.sh --list-broken and is structural: driver gone, buses gone, or a
# hub that enumerated but failed to configure (maxchild=0), which is the
# signature of the real 22:40 failure.
#
# WHY IT GIVES UP
#
# If a controller re-wedges immediately after every recovery, the recovery is
# not working and the loop would otherwise re-enumerate the bus every few
# seconds indefinitely -- which is worse for the user than a dead bus, because
# input devices flap instead of simply being absent. After MAX recoveries in
# WINDOW seconds it logs loudly and stops trying until the unit is restarted.
set -uo pipefail

INTERVAL=${USB_WATCHDOG_INTERVAL:-5}
MAX=${USB_WATCHDOG_MAX:-5}
WINDOW=${USB_WATCHDOG_WINDOW:-900}

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
RESET="$HERE/usb-reset.sh"

# Journald captures stdout; the prefixes make `journalctl -u ...` readable
# without timestamps of its own.
log()  { printf 'usb-watchdog: %s\n' "$*"; }
warn() { printf 'usb-watchdog: [warn] %s\n' "$*" >&2; }

[[ -x "$RESET" ]] || { warn "missing $RESET"; exit 1; }

# Single source of truth: the same predicate the reset itself uses, so the
# thing that decides to act and the thing that decides it worked can never
# disagree.
broken_controllers() { "$RESET" --list-broken 2>/dev/null; }

# Recovery timestamps inside the current window.
recoveries=()

prune_recoveries() {
    local now=$1 keep=() t
    for t in "${recoveries[@]:-}"; do
        [[ -n "$t" ]] && (( now - t < WINDOW )) && keep+=("$t")
    done
    recoveries=("${keep[@]:-}")
}

log "started (interval=${INTERVAL}s, give up after ${MAX} recoveries per ${WINDOW}s)"

while true; do
    mapfile -t broken < <(broken_controllers)
    if [[ ${#broken[@]} -gt 0 && -n "${broken[0]}" ]]; then
        now=$SECONDS
        prune_recoveries "$now"
        # ${#recoveries[@]} counts a lone empty element as 1, so filter first.
        n=0; for t in "${recoveries[@]:-}"; do [[ -n "$t" ]] && ((n++)); done

        if (( n >= MAX )); then
            warn "controller(s) ${broken[*]} broken, but ${n} recoveries already in the last ${WINDOW}s -- giving up"
            warn "recovery is not holding; this needs the physical fixes in hardware/usb/README.md"
            warn "restart this unit to try again: systemctl restart steam-machine-usb-watchdog"
            exit 1
        fi

        log "broken: ${broken[*]} -- recovering (attempt $((n + 1))/${MAX} in window)"
        if "$RESET" --broken; then
            log "recovery succeeded"
        else
            warn "recovery FAILED"
        fi
        recoveries+=("$now")
    fi
    sleep "$INTERVAL"
done
