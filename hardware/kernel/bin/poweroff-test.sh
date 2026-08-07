#!/usr/bin/env bash
#
# Bisect the power-off hang described in ../README.md under
# "OPEN: power-off hangs".
#
# The symptom: systemd completes the entire shutdown sequence, then the machine
# never reaches S5 -- fans and LEDs stay on, the HDMI link stays up (the TV
# still reports a signal), and only a 4-5 second power-button hold kills it.
# /sys/fs/pstore is empty every time, so it is a hang and not a panic.
#
# Each mode powers the machine off a different way, removing one layer. Run
# them over SSH: the session dies when the machine goes down, and if it hangs
# instead you will simply stay connected with no further output.
#
# Whatever happens, a marker is written to /home/deck/.poweroff-test BEFORE the
# attempt, recording which mode ran. After the next boot, --report reads it back
# alongside wtmp and pstore, so a power-cycle does not lose which test this was.
#
# Usage:
#   sudo ./poweroff-test.sh --report        what happened last time (safe, read-only)
#   sudo ./poweroff-test.sh --plain         control: an ordinary poweroff
#   sudo ./poweroff-test.sh --no-gpu        tear the display stack down and unload amdgpu first
#   sudo ./poweroff-test.sh --sysrq         skip systemd entirely: sync, then SysRq-o
#
# --no-gpu is the one that discriminates. If the machine powers off with amdgpu
# unloaded but hangs with it loaded, the fault is in the driver's teardown path
# and the VRR patches are the prime suspect. If it hangs either way, amdgpu is
# not the cause and this is firmware or ACPI.

set -euo pipefail

MARKER=/home/deck/.poweroff-test
MODE="${1:-}"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || die "must run as root (SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A $0 $MODE)"

# --- report -------------------------------------------------------------------

if [[ "$MODE" == "--report" ]]; then
    if [[ -f "$MARKER" ]]; then
        log "last attempt"
        cat "$MARKER"
    else
        warn "no marker at $MARKER -- no test has been run yet"
    fi

    echo
    log "wtmp (a 'shutdown system down' line means systemd finished; it says nothing about S5)"
    last -n 6 -x | head -8

    echo
    log "pstore (empty = hang, non-empty = panic or oops was captured)"
    ls -la /sys/fs/pstore/ 2>&1 | tail -n +2

    echo
    log "verdict"
    # A hang leaves no clean gap: the marker is from the attempt, and the boot
    # after it either follows immediately (powered off, then switched on) or
    # shows the forced 4-second hold. Only the human knows which, so ask.
    echo "  Did the machine power itself off, or did you have to hold the button?"
    echo "  Record the answer against the mode above in ../README.md."
    exit 0
fi

# --- guard --------------------------------------------------------------------

case "$MODE" in
    --plain|--no-gpu|--sysrq) ;;
    *) die "usage: $0 --report | --plain | --no-gpu | --sysrq" ;;
esac

log "kernel:  $(uname -r)"
log "mode:    $MODE"
warn "this powers the machine off. Any unsaved work in the desktop session is lost."
echo

# Record the attempt before anything can wedge.
{
    echo "date:   $(date -Is)"
    echo "mode:   $MODE"
    echo "kernel: $(uname -r)"
    echo "cmdline: $(cat /proc/cmdline)"
} > "$MARKER"
chown deck:deck "$MARKER"

sync
log "filesystems synced"

# --- --no-gpu: unload the display driver before shutting down -----------------

if [[ "$MODE" == "--no-gpu" ]]; then
    log "stopping the graphical session"
    systemctl isolate multi-user.target || warn "isolate returned non-zero, continuing"
    sleep 2

    # fbcon keeps a reference to the DRM framebuffer, so amdgpu will not unload
    # while a virtual console is bound to it. Unbind every vtcon that is not the
    # dummy device.
    for v in /sys/class/vtconsole/vtcon*; do
        [[ -r "$v/name" ]] || continue
        name="$(cat "$v/name")"
        if [[ "$name" != *dummy* ]]; then
            log "unbinding console: $(basename "$v") ($name)"
            echo 0 > "$v/bind" 2>/dev/null || warn "could not unbind $(basename "$v")"
        fi
    done
    sleep 1

    log "unloading amdgpu"
    if modprobe -r amdgpu 2>&1; then
        log "amdgpu unloaded"
    else
        warn "amdgpu would not unload -- something still holds the DRM device"
        lsof /dev/dri/* 2>/dev/null | head || true
        die "test is inconclusive with the driver still loaded; nothing was powered off"
    fi

    if lsmod | grep -q '^amdgpu'; then
        die "amdgpu still listed in lsmod; refusing to continue"
    fi

    echo "amdgpu: unloaded successfully" >> "$MARKER"
    log "display driver is gone -- powering off now"
    sleep 1
fi

# --- --sysrq: bypass systemd's shutdown entirely ------------------------------

if [[ "$MODE" == "--sysrq" ]]; then
    log "enabling all SysRq functions"
    echo 1 > /proc/sys/kernel/sysrq

    log "SysRq: sync, then remount read-only"
    echo s > /proc/sysrq-trigger
    sleep 2
    echo u > /proc/sysrq-trigger
    sleep 2

    log "SysRq: power off (bypasses systemd, calls the kernel poweroff path)"
    echo o > /proc/sysrq-trigger

    # If SysRq-o worked we never get here.
    sleep 10
    die "SysRq-o did not power the machine off -- the kernel poweroff path itself is stuck"
fi

# --- go -----------------------------------------------------------------------

log "calling systemctl poweroff"
systemctl poweroff
