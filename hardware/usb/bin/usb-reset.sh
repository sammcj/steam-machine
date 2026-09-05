#!/usr/bin/env bash
# Reset USB controllers when the bus wedges. See ../README.md.
#
#   usb-reset.sh                 reset every xHCI controller
#   usb-reset.sh --broken        reset only controllers that are actually broken
#   usb-reset.sh --controller X  reset one, e.g. --controller 0000:12:00.4
#   usb-reset.sh --status        report controller state, change nothing
#   usb-reset.sh --dry-run       print what would happen
#   usb-reset.sh --force         proceed past the mounted-filesystem / default-route guards
#
# WHY THIS EXISTS
#
# A hub error storm on this machine wedges the xHC command ring. The *next*
# runtime-suspend attempt then times out inside xhci_suspend()'s 20 ms
# STS_SAVE handshake:
#
#   xhci_hcd 0000:12:00.4: Controller Save State failed -110
#   xhci_hcd 0000:12:00.4: can't suspend (hcd_pci_runtime_suspend returned -110)
#
# which sets dev->power.runtime_error. Once set, rpm_resume() and
# rpm_check_suspend_allowed() return -EINVAL unconditionally, forever, and
# power/runtime_status reads "error" ahead of the real state
# (drivers/base/power/{runtime,sysfs}.c). There is no sysfs write that clears
# it -- runtime_status is DEVICE_ATTR_RO, and the flag is only cleared inside
# __pm_runtime_set_status(), which is kernel-internal.
#
# So the only userspace fix is to destroy and re-create the struct device.
#
# TWO TIERS, IN ORDER
#
#   1. unbind + rebind xhci_hcd. Cheaper, and usually enough to get the bus
#      back. It does NOT reliably clear runtime_error -- pm_runtime_reinit()
#      on the unbind path early-returns while runtime PM is still enabled --
#      so the status is re-checked afterwards.
#   2. PCI remove + rescan. Destroys the pci_dev outright, so the rebuilt
#      device starts with runtime_error = 0. This is what actually recovered
#      the machine on 2026-09-05.
#
# Tier 2 is more disruptive: every device on the controller re-enumerates, a
# USB NIC disappears and comes back with a new interface name, and a mounted
# USB filesystem takes I/O errors. Hence the guards below.
set -uo pipefail

_lib() {
    local d; d=$(readlink -f "${BASH_SOURCE[0]}"); d=${d%/*}
    while [[ $d != / ]]; do
        [[ -r $d/lib/elevate.sh ]] && { printf '%s\n' "$d/lib/elevate.sh"; return 0; }
        d=${d%/*}
    done
    return 1
}
_l=$(_lib) && source "$_l"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

DRIVER_DIR=/sys/bus/pci/drivers/xhci_hcd
PCI_CLASS_XHCI=0x0c0330

DRY_RUN=0
FORCE=0
ONLY_BROKEN=0
ONE_CONTROLLER=
MODE=reset

# --- discovery ---------------------------------------------------------------

# Every xHCI PCI function, bound or not. Matched on PCI class rather than a
# hardcoded address: this board has renumbered its USB controllers across a
# firmware update already (11:00.4 -> 12:00.4), and hardware/audio/README.md
# still carries the stale address as a result.
controllers() {
    local d
    for d in /sys/bus/pci/devices/*/; do
        [[ -r "$d/class" ]] || continue
        [[ "$(cat "$d/class")" == "$PCI_CLASS_XHCI" ]] && basename "$d"
    done
}

rt_status()  { cat "/sys/bus/pci/devices/$1/power/runtime_status" 2>/dev/null || echo gone; }
rt_control() { cat "/sys/bus/pci/devices/$1/power/control"        2>/dev/null || echo gone; }
is_bound()   { [[ -e "$DRIVER_DIR/$1" ]]; }

# USB buses belonging to a controller, e.g. "usb5 usb6".
buses_of() {
    local addr=$1 b
    for b in /sys/bus/usb/devices/usb*; do
        [[ -e "$b" ]] || continue
        [[ "$(readlink -f "$b/..")" == */"$addr" ]] && basename "$b"
    done
}

# USB devices (not root hubs) currently enumerated under a controller.
device_count_of() {
    local addr=$1 n=0 d
    for d in /sys/bus/usb/devices/*/; do
        d=${d%/}
        [[ "$(basename "$d")" == usb* ]] && continue
        [[ "$(basename "$d")" == *:* ]] && continue
        [[ "$(readlink -f "$d")" == */"$addr"/* ]] && ((n++))
    done
    echo "$n"
}

# --- is this controller actually broken? -------------------------------------
#
# NOT the same question as "is runtime_status error". Learned the hard way on
# 2026-09-05: the controller sat at runtime_status=error with all ten devices
# present and working, and an earlier version of this script treated that as
# broken and did a disruptive remove/rescan on a perfectly functional bus.
#
# runtime_error only means the device can never runtime-suspend again. With
# udev.rules.d/ pinning power/control=on that is harmless -- the suspend path
# it blocks is one we do not want to run anyway. It is reported by --status as
# information, and is deliberately not a trigger.
#
# What *is* broken, from the actual 22:40 failure:
#
#   hub 5-2:1.0: 4 ports detected
#   hub 5-2:1.0: config failed, can't get hub status (err -5)
#
# The hub enumerated, the hub driver probed, and configuration failed -- so the
# device is present with maxchild=0 and no driver on its interface, and every
# device behind it is unreachable. A healthy hub reads class=09, maxchild=4,
# driver=hub. That, plus the two coarser cases (driver gone, buses gone), is
# the whole test.
broken_reason() {
    local addr=$1 d base

    [[ -e "/sys/bus/pci/devices/$addr" ]] || { echo "PCI device is gone"; return 0; }
    if ! is_bound "$addr"; then
        echo "not bound to xhci_hcd"
        return 0
    fi
    if [[ -z "$(buses_of "$addr")" ]]; then
        echo "bound but no USB buses registered"
        return 0
    fi

    for d in /sys/bus/usb/devices/*/; do
        d=${d%/}; base=$(basename "$d")
        [[ "$base" == usb* || "$base" == *:* ]] && continue
        [[ "$(readlink -f "$d")" == */"$addr"/* ]] || continue
        [[ "$(cat "$d/bDeviceClass" 2>/dev/null)" == 09 ]] || continue
        if [[ "$(cat "$d/maxchild" 2>/dev/null)" == 0 ]]; then
            echo "hub $base failed to configure (maxchild=0) -- everything behind it is unreachable"
            return 0
        fi
    done
    return 1
}

broken_controllers() {
    local addr
    for addr in $(controllers); do
        broken_reason "$addr" >/dev/null && echo "$addr"
    done
    return 0
}

# --- guards ------------------------------------------------------------------
#
# Both are advisory and both are overridable with --force. They exist because
# the failure they prevent is silent: an unmounted-underneath filesystem shows
# up as I/O errors much later, and a dropped default route locks you out of a
# machine whose only console is a TV.

# Mount points whose backing block device sits under this controller.
mounts_on() {
    local addr=$1 src mp real
    while read -r src mp _; do
        [[ "$src" == /dev/* ]] || continue
        real=$(readlink -f "/sys/class/block/$(basename "$src")" 2>/dev/null) || continue
        [[ "$real" == */"$addr"/* ]] && printf '%s (%s)\n' "$mp" "$src"
    done < /proc/mounts | sort -u
}

# The interface carrying the default route, if it lives under this controller.
# A USB NIC on the same controller as everything else is exactly the kind of
# thing that turns a routine reset into a lockout.
default_route_on() {
    local addr=$1 iface real
    iface=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [[ -n "$iface" ]] || return 1
    real=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null) || return 1
    [[ "$real" == */"$addr"/* ]] && { echo "$iface"; return 0; }
    return 1
}

# Returns 0 if it is safe to proceed (or --force was given).
check_guards() {
    local addr=$1 blocked=0 mounts iface
    mounts=$(mounts_on "$addr")
    if [[ -n "$mounts" ]]; then
        warn "$addr has mounted filesystems:"
        printf '  %s\n' $mounts >&2
        blocked=1
    fi
    if iface=$(default_route_on "$addr"); then
        warn "$addr carries the default route ($iface) -- resetting it will drop the network"
        blocked=1
    fi
    [[ $blocked -eq 0 ]] && return 0
    if [[ $FORCE -eq 1 ]]; then
        warn "--force given, proceeding anyway"
        return 0
    fi
    err "refusing to reset $addr -- re-run with --force to override"
    return 1
}

# --- reset -------------------------------------------------------------------

# Poll until the controller is bound with its buses back, or the deadline
# passes. Fixed sleeps were wrong in both directions here: a rebind can take
# well over a second on this controller, and polling returns as soon as it is
# actually done.
wait_healthy() {
    local addr=$1 deadline=$((SECONDS + ${2:-15}))
    while (( SECONDS < deadline )); do
        if ! broken_reason "$addr" >/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

tier1_rebind() {
    local addr=$1
    log "$addr: unbind/rebind xhci_hcd"
    [[ $DRY_RUN -eq 1 ]] && return 0
    if is_bound "$addr"; then
        echo "$addr" > "$DRIVER_DIR/unbind" 2>/dev/null || {
            warn "$addr: unbind failed"; return 1; }
    fi
    sleep 2
    echo "$addr" > "$DRIVER_DIR/bind" 2>/dev/null || {
        warn "$addr: bind failed"; return 1; }
    wait_healthy "$addr" 15
}

tier2_remove_rescan() {
    local addr=$1
    log "$addr: PCI remove + rescan"
    [[ $DRY_RUN -eq 1 ]] && return 0
    # remove can itself block if the xHC is hard-hung, because xhci_pci_remove
    # talks to the controller. Bound in time rather than hanging the watchdog.
    if ! timeout 30 sh -c "echo 1 > /sys/bus/pci/devices/$addr/remove" 2>/dev/null; then
        warn "$addr: remove timed out or failed"
    fi
    sleep 2
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || warn "rescan failed"
    wait_healthy "$addr" 25
}

reset_one() {
    local addr=$1 before_devs
    before_devs=$(device_count_of "$addr")
    check_guards "$addr" || return 1

    if tier1_rebind "$addr"; then
        log "$addr: recovered by rebind (status=$(rt_status "$addr"), $(device_count_of "$addr") devices)"
        return 0
    fi
    warn "$addr: still unhealthy after rebind (status=$(rt_status "$addr"))"

    if tier2_remove_rescan "$addr"; then
        log "$addr: recovered by remove/rescan (status=$(rt_status "$addr"), $(device_count_of "$addr") devices)"
        return 0
    fi
    err "$addr: STILL unhealthy after remove/rescan (status=$(rt_status "$addr"), was $before_devs devices)"
    return 1
}

# --- modes -------------------------------------------------------------------

do_status() {
    printf '%-16s %-8s %-9s %-10s %-7s %s\n' CONTROLLER BOUND CONTROL STATUS DEVICES BUSES
    local addr
    for addr in $(controllers); do
        printf '%-16s %-8s %-9s %-10s %-7s %s\n' \
            "$addr" \
            "$(is_bound "$addr" && echo yes || echo NO)" \
            "$(rt_control "$addr")" \
            "$(rt_status "$addr")" \
            "$(device_count_of "$addr")" \
            "$(buses_of "$addr" | tr '\n' ' ')"
    done
    echo
    local addr reason broken=0
    for addr in $(controllers); do
        if reason=$(broken_reason "$addr"); then
            warn "$addr is BROKEN: $reason"
            broken=1
        elif [[ "$(rt_status "$addr")" == error ]]; then
            # Information, not a fault. See broken_reason() for why.
            log "$addr: runtime_status=error, but the bus is working. Harmless while"
            log "    power/control=on; it only means the controller can never runtime-suspend"
            log "    again this boot. Clears on reboot, or on the next --broken reset."
        fi
    done
    if [[ $broken -eq 1 ]]; then
        echo "  fix: $(basename "${BASH_SOURCE[0]}") --broken"
    else
        log "no controller is broken"
    fi
}

do_reset() {
    need_root "$@"
    local targets addr rc=0
    if [[ -n "$ONE_CONTROLLER" ]]; then
        [[ -e "/sys/bus/pci/devices/$ONE_CONTROLLER" ]] \
            || die "no such PCI device: $ONE_CONTROLLER"
        targets=$ONE_CONTROLLER
    elif [[ $ONLY_BROKEN -eq 1 ]]; then
        targets=$(broken_controllers)
        [[ -z "$targets" ]] && { log "nothing broken, nothing to do"; return 0; }
    else
        targets=$(controllers)
    fi

    for addr in $targets; do
        reset_one "$addr" || rc=1
    done

    # A rebind re-runs the udev rule, but a controller that was never removed
    # keeps whatever power/control it had. Re-assert it so a reset never leaves
    # runtime PM armed on a controller that just misbehaved.
    for addr in $targets; do
        [[ -w "/sys/bus/pci/devices/$addr/power/control" ]] \
            && echo on > "/sys/bus/pci/devices/$addr/power/control" 2>/dev/null
    done

    echo
    do_status
    return $rc
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)     MODE=status ;;
        --broken)     ONLY_BROKEN=1 ;;
        # Old name, kept so a copied-and-pasted command from the journal or the
        # README's history still works.
        --wedged)     ONLY_BROKEN=1 ;;
        --list-broken) MODE=list-broken ;;
        --controller) ONE_CONTROLLER="${2:?--controller needs a PCI address}"; shift ;;
        --dry-run)    DRY_RUN=1 ;;
        --force)      FORCE=1 ;;
        -h|--help)    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)            die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

case "$MODE" in
    status)      do_status ;;
    list-broken) broken_controllers ;;
    reset)       do_reset ;;
esac
