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

NIC_PCI=0000:09:00.0
NIC_DEV=enp9s0

case "$MODE" in
    --plain|--no-lact|--no-oot|--no-gpu|--no-net|--no-netwake|--sysrq) ;;
    *) die "usage: $0 --report | --plain | --no-lact | --no-oot | --no-gpu | --no-net | --no-netwake | --sysrq" ;;
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

# Make the shutdown visible on the TV. This is done at runtime rather than with
# boot parameters, because boot parameters do not work here:
#
#   * `plymouth.enable=0` never reaches the kernel -- steamenv_boot strips it.
#     Verified in /proc/cmdline after adding it to custom.cfg.
#   * `fbcon=vc:4-6` is appended by steamenv_boot, so the framebuffer console
#     renders only VCs 4-6. The system sits on VC1, which nothing draws, which
#     is why killing the splash leaves a black screen rather than a log.
#   * `quiet` is appended after anything custom.cfg sets.
#
# So: switch to a VC the framebuffer console actually owns, stop plymouth
# letting go of the display, and raise printk to everything.
make_console_visible() {
    if command -v chvt >/dev/null; then
        log "switching to VC4 (the first console fbcon renders)"
        chvt 4 || warn "chvt 4 failed -- output may not be visible"
    fi
    # Quitting plymouth is not enough on its own. plymouth-poweroff.service is
    # in poweroff.target.wants, so systemd starts the splash again for the
    # shutdown itself and paints over the console at exactly the moment worth
    # watching. That is why every attempt before 2026-08-08 showed a blank
    # screen. Mask the shutdown-path units; they only draw a splash.
    for u in plymouth-poweroff.service plymouth-reboot.service plymouth-halt.service; do
        if ! systemctl is-enabled "$u" 2>/dev/null | grep -q masked; then
            systemctl mask "$u" >/dev/null 2>&1 && log "masked $u" \
                || warn "could not mask $u"
        fi
    done

    if command -v plymouth >/dev/null && plymouth --ping 2>/dev/null; then
        log "stopping plymouth so it releases the framebuffer"
        plymouth quit --retain-splash=false 2>/dev/null || true
    fi

    # Make systemd narrate the shutdown on the console too, so the last unit to
    # run is visible alongside the kernel messages.
    systemctl log-level debug 2>/dev/null || true
    systemctl log-target console 2>/dev/null || true
    # 7 4 1 7: console_loglevel 7, so everything up to KERN_DEBUG prints.
    echo 7 4 1 7 > /proc/sys/kernel/printk
    echo 1 > /proc/sys/kernel/sysrq

    # The important one. device_shutdown() in drivers/base/core.c prints the name
    # of every device immediately BEFORE calling its shutdown handler, gated on
    # initcall_debug:
    #
    #     if (dev->bus && dev->bus->shutdown) {
    #             if (initcall_debug)
    #                     dev_info(dev, "shutdown\n");
    #             dev->bus->shutdown(dev);
    #     }
    #
    # So if a handler never returns, the LAST name on screen is the device that
    # hung - no need to guess which driver to unload next. It is a core_param,
    # writable at runtime, so this needs no rebuild and no reboot.
    if [[ -w /sys/module/kernel/parameters/initcall_debug ]]; then
        echo Y > /sys/module/kernel/parameters/initcall_debug
        log "initcall_debug on -- every device prints its name before shutting down"
        echo "initcall_debug: on" >> "$MARKER"
    else
        warn "initcall_debug not writable -- per-device trace unavailable"
    fi
    log "console verbosity raised -- watch the TV from here"
    sleep 2
}
make_console_visible

# --- --no-net / --no-netwake: the Realtek NIC ---------------------------------

# `r8169 0000:09:00.0 enp9s0: Link is Down` is the LAST line on the console
# before the machine wedges (captured 2026-08-08). It comes from rtl8169_down().
# What runs straight after it is the Wake-on-LAN setup and the PCI transition
# into D3 - and PCI wakeup is enabled on this device, so that path is live.
#
#   --no-netwake  disables PCI wakeup for the NIC only. If this powers off, WoL
#                 setup is the trigger, and the cost of the fix is losing
#                 Wake-on-LAN (which is used on this machine).
#   --no-net      unloads r8169 entirely. The definitive "is it this driver"
#                 test. NOTE: this kills SSH, so watch the TV, not the terminal.
if [[ "$MODE" == "--no-netwake" ]]; then
    if [[ -w "/sys/bus/pci/devices/$NIC_PCI/power/wakeup" ]]; then
        log "disabling PCI wakeup on $NIC_DEV ($NIC_PCI)"
        echo disabled > "/sys/bus/pci/devices/$NIC_PCI/power/wakeup"
        echo "nic wakeup: $(cat "/sys/bus/pci/devices/$NIC_PCI/power/wakeup")" >> "$MARKER"
    else
        warn "no writable wakeup attribute for $NIC_PCI"
    fi
    sleep 1
fi

if [[ "$MODE" == "--no-net" ]]; then
    warn "this drops the network -- your SSH session will freeze. Watch the TV."
    sleep 3
    log "bringing $NIC_DEV down"
    ip link set "$NIC_DEV" down 2>/dev/null || warn "could not down $NIC_DEV"
    log "unloading r8169"
    if modprobe -r r8169 2>&1; then
        echo "r8169: unloaded" >> "$MARKER"
    else
        echo "r8169: FAILED to unload" >> "$MARKER"
        warn "r8169 would not unload"
    fi
    lsmod | grep -q '^r8169' && warn "r8169 STILL LOADED" || true
    sleep 1
fi

# --- --no-oot: unload the two out-of-tree modules -----------------------------

# Two modules on this machine are built locally rather than shipped by the
# kernel: it87 (Super-I/O hwmon, from the out-of-tree tree) and btusb_mt7902
# (backported MT7902 Bluetooth). Both are rebuilt per kernel version, so both
# are among the few things that genuinely differ from a plain mainline build.
#
# it87 is the one to suspect. It drives the Super-I/O chip through raw I/O
# ports that ACPI also claims -- which is why this machine boots with
# acpi_enforce_resources=lax at all. A driver poking ports the firmware's own
# ASL uses is a credible way to break an S5 transition.
if [[ "$MODE" == "--no-oot" ]]; then
    for m in it87 btusb_mt7902; do
        if lsmod | grep -q "^$m "; then
            log "unloading $m"
            if modprobe -r "$m" 2>&1; then
                echo "$m: unloaded" >> "$MARKER"
            else
                warn "could not unload $m"
                echo "$m: FAILED to unload" >> "$MARKER"
            fi
        else
            log "$m is not loaded"
            echo "$m: not loaded" >> "$MARKER"
        fi
    done

    # hwmon_vid is only pulled in by it87 and lingers after it goes.
    lsmod | grep -q '^hwmon_vid ' && modprobe -r hwmon_vid 2>/dev/null || true

    log "remaining out-of-tree modules:"
    for m in it87 btusb_mt7902; do
        lsmod | grep -q "^$m " && warn "  $m STILL LOADED" || log "  $m gone"
    done
    sleep 1
fi

# --- --no-lact: stop the GPU control daemon, leave everything else alone ------

# LACT holds both DRM render nodes open for the whole uptime, as a root daemon
# out of a Flatpak. --no-gpu has to stop it to unload amdgpu at all, which
# conflates two variables; this mode separates them. Run it FIRST: if the
# machine powers off with only LACT stopped, the driver is not implicated and
# --no-gpu never needs running.
if [[ "$MODE" == "--no-lact" ]]; then
    if systemctl is-active --quiet lactd.service; then
        log "stopping lactd.service"
        systemctl stop lactd.service || die "could not stop lactd.service"
        echo "lactd: stopped" >> "$MARKER"
    else
        warn "lactd.service was not running -- this mode is the same as --plain"
        echo "lactd: was not running" >> "$MARKER"
    fi
    sleep 2

    if command -v lsof >/dev/null && lsof /dev/dri/* >/dev/null 2>&1; then
        log "still holding a DRM node (expected: the graphical session):"
        lsof /dev/dri/* 2>/dev/null | tail -n +2 | sed 's/^/    /'
    fi
fi

# --- --no-gpu: unload the display driver before shutting down -----------------

if [[ "$MODE" == "--no-gpu" ]]; then
    log "stopping the graphical session"
    systemctl isolate multi-user.target || warn "isolate returned non-zero, continuing"
    sleep 2

    # Daemons that hold a DRM node open outside the graphical session, so
    # isolating multi-user.target does not clear them. LACT keeps both render
    # nodes open for the whole uptime; without stopping it amdgpu will not
    # unload and the test cannot run.
    for unit in lactd.service; do
        if systemctl is-active --quiet "$unit"; then
            log "stopping $unit (holds a DRM node)"
            systemctl stop "$unit" || warn "could not stop $unit"
        fi
    done
    sleep 2

    # Report anything still holding the device before trying to unload, so a
    # failure below names the culprit instead of just saying "in use".
    if command -v lsof >/dev/null && lsof /dev/dri/* >/dev/null 2>&1; then
        warn "still holding a DRM node:"
        lsof /dev/dri/* 2>/dev/null | tail -n +2 | sed 's/^/    /'
    fi

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
