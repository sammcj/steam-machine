#!/usr/bin/env bash
# Idle power tunables, and the measurement tool for deciding whether any future
# one is worth having.
#
#   ./install.sh              install the sysctl config, keep entry and boot unit
#   ./install.sh --boot       boot-time path: restore anything a SteamOS update
#                             dropped from /etc, then apply it. Run by the unit
#   ./install.sh --status     report state and measure idle power (see below)
#   ./install.sh --restore-freq  undo a CPU frequency clamp left by powertop
#   ./install.sh --uninstall  remove everything and restore kernel defaults
#
# Nothing lands in /usr, which SteamOS replaces wholesale on every A/B update.
# The config goes in /etc (an overlay: survives reboots unconditionally,
# survives updates only via the atomic-update.conf.d entry) and everything else
# lives in this repo under /home.
#
# No reboot required: both tunables are runtime-writable, unlike the modprobe
# parameters in hardware/gpu/ and hardware/sensors/.
#
# --status is the point of this script as much as the install is. It samples
# package power from RAPL and C-state residency as *deltas over an interval*,
# which is the only way to get an honest idle figure -- see the long comment on
# read_cstates() for why the numbers everything else reports are misleading.
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

SYSCTL_SRC="$REPO_DIR/sysctl.d/60-steam-machine-power.conf"
SYSCTL_DEST="/etc/sysctl.d/60-steam-machine-power.conf"
UDEV_SRC="$REPO_DIR/udev.rules.d/60-steam-machine-power.rules"
UDEV_DEST="/etc/udev/rules.d/60-steam-machine-power.rules"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-power.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-power.conf"
UNIT_SRC="$REPO_DIR/systemd/steam-machine-power.service"
UNIT_DEST="/etc/systemd/system/steam-machine-power.service"

# The AMD RAPL driver registers under the intel-rapl name. package-0 is the
# whole socket (cores + IOD + Infinity Fabric); intel-rapl:0:0 is cores only.
RAPL_PKG="/sys/class/powercap/intel-rapl:0"

# Seconds to sample over in --status. Long enough to average out a Steam UI
# frame or a coolercontrold poll, short enough to not feel broken.
SAMPLE="${POWER_SAMPLE_SECONDS:-10}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# need_root() now comes from lib/elevate.sh -- it elevates before dying.
# --- measurement --------------------------------------------------------------

# Sum the per-state idle times across every CPU, in microseconds, as a single
# "state<TAB>usec" table on stdout.
#
# These counters are cumulative since boot, which is why --status samples them
# twice and subtracts. A cumulative read answers "how idle has this machine been
# since it booted", which is not the question -- if the box spent an hour
# compiling this morning it will look busy all day.
read_cstates() {
    awk '
        {
            split(FILENAME, p, "/")
            # /sys/devices/system/cpu/cpuN/cpuidle/stateM/time -> field 8 = stateM
            state = p[8]
            time[state] += $1
        }
        END { for (s in time) printf "%s\t%d\n", s, time[s] }
    ' /sys/devices/system/cpu/cpu*/cpuidle/state*/time | sort
}

# Human name for stateN, taken from cpu0 (identical across cores on this box).
cstate_name() {
    cat "/sys/devices/system/cpu/cpu0/cpuidle/$1/name" 2>/dev/null || printf '%s' "$1"
}

nproc_online() { grep -c '^processor' /proc/cpuinfo; }

# Package energy in microjoules, or empty if unreadable.
#
# energy_uj is root-only on this kernel (mode 0400 since the PLATYPUS side
# channel disclosure), so --status degrades to "not readable" rather than
# failing when run as deck.
read_energy() { cat "$RAPL_PKG/energy_uj" 2>/dev/null || true; }

# RAPL counters wrap at max_energy_range_uj. Over a 10 s sample at desktop-idle
# power a wrap is unlikely but not impossible, and a wrap read naively prints a
# hugely negative wattage -- which is exactly the sort of number someone would
# screenshot and act on.
energy_delta() {
    local a="$1" b="$2" max
    if (( b >= a )); then
        printf '%s' $((b - a))
        return
    fi
    max="$(cat "$RAPL_PKG/max_energy_range_uj" 2>/dev/null || echo 0)"
    if (( max > 0 )); then
        printf '%s' $((max - a + b))
    else
        printf ''
    fi
}

do_measure() {
    local e1 e2 t1 t2 c1 c2 ncpu elapsed_us delta_uj

    ncpu="$(nproc_online)"
    c1="$(read_cstates)"
    e1="$(read_energy)"
    t1="$(date +%s%N)"

    # `sleep` is unavailable in some non-interactive contexts on this box; this
    # form blocks reliably everywhere and needs no external timer.
    timeout "$SAMPLE" tail -f /dev/null || true

    t2="$(date +%s%N)"
    e2="$(read_energy)"
    c2="$(read_cstates)"

    elapsed_us=$(( (t2 - t1) / 1000 ))
    (( elapsed_us > 0 )) || { warn "zero-length sample"; return; }

    printf 'sampled over %.1f s across %s cores\n\n' "$(awk -v u="$elapsed_us" 'BEGIN{print u/1e6}')" "$ncpu"

    printf '  %-22s ' "CPU package power"
    if [[ -n "$e1" && -n "$e2" ]]; then
        delta_uj="$(energy_delta "$e1" "$e2")"
        if [[ -n "$delta_uj" ]]; then
            awk -v uj="$delta_uj" -v us="$elapsed_us" 'BEGIN{printf "%.2f W\n", uj/us}'
        else
            echo "counter wrapped -- re-run"
        fi
    elif [[ $EUID -ne 0 ]]; then
        echo "not readable (RAPL energy_uj is root-only; re-run with sudo)"
    else
        echo "not available ($RAPL_PKG/energy_uj missing)"
    fi

    local gpu_uw
    gpu_uw="$(cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_average 2>/dev/null | head -1 || true)"
    printf '  %-22s ' "dGPU board power"
    [[ -n "$gpu_uw" ]] && awk -v uw="$gpu_uw" 'BEGIN{printf "%.1f W\n", uw/1e6}' || echo "?"

    echo
    echo "  idle residency (share of all core-time in the sample):"
    # Join the two snapshots on the state key and turn the delta into a
    # percentage of total available core-microseconds.
    join -t $'\t' <(printf '%s\n' "$c1") <(printf '%s\n' "$c2") \
        | while IFS=$'\t' read -r state before after; do
            printf '    %-6s %5.1f%%\n' "$(cstate_name "$state")" \
                "$(awk -v d="$((after - before))" -v us="$elapsed_us" -v n="$ncpu" \
                    'BEGIN{print (d*100)/(us*n)}')"
        done
}

# --- /etc self-heal -----------------------------------------------------------
# Cheap and idempotent, so it is safe on the boot fast path, and it runs BEFORE
# any early exit. /etc is an overlayfs with its upper layer in /var, writable
# even when steamos-readonly is enabled, so this needs no rootfs unlock.
ensure_etc_config() {
    local src dest
    for src in "$SYSCTL_SRC" "$UDEV_SRC" "$KEEP_SRC" "$UNIT_SRC"; do
        case "$src" in
            "$SYSCTL_SRC") dest="$SYSCTL_DEST" ;;
            "$UDEV_SRC")   dest="$UDEV_DEST" ;;
            "$KEEP_SRC")   dest="$KEEP_DEST" ;;
            *)             dest="$UNIT_DEST" ;;
        esac
        if ! cmp -s "$src" "$dest"; then
            install -Dm644 "$src" "$dest"
            warn "restored $dest (was missing or modified)"
        fi
    done
}

# Re-apply the SATA link policy to hosts that already exist.
#
# udev only fires the rule on add/change events, so on a boot where the rule was
# restored *after* the ahci hosts appeared it would otherwise not take effect
# until the next reboot -- the same same-boot gap the sysctl re-apply closes.
apply_udev() {
    udevadm control --reload >/dev/null 2>&1 || warn "udevadm control --reload failed"
    udevadm trigger --subsystem-match=scsi_host --action=change >/dev/null 2>&1 \
        || warn "udevadm trigger failed"
}

# Apply the sysctl file now. Unconditional rather than only-when-restored:
# something else could have changed these at runtime, and re-applying a value
# that is already set costs nothing.
apply_sysctl() {
    if [[ -f "$SYSCTL_DEST" ]]; then
        sysctl -q -p "$SYSCTL_DEST" || warn "sysctl -p $SYSCTL_DEST failed"
    fi
}

# --- top level ----------------------------------------------------------------
do_install() {
    need_root

    [[ -f "$SYSCTL_SRC" ]] || die "missing $SYSCTL_SRC"

    log "installing $SYSCTL_DEST"
    install -Dm644 "$SYSCTL_SRC" "$SYSCTL_DEST"

    log "installing $UDEV_DEST"
    install -Dm644 "$UDEV_SRC" "$UDEV_DEST"

    log "installing $KEEP_DEST (survives SteamOS A/B updates)"
    install -Dm644 "$KEEP_SRC" "$KEEP_DEST"

    log "installing $UNIT_DEST"
    install -Dm644 "$UNIT_SRC" "$UNIT_DEST"
    systemctl daemon-reload
    systemctl enable steam-machine-power.service >/dev/null 2>&1 \
        || warn "could not enable steam-machine-power.service"

    log "applying now (no reboot needed -- everything here is runtime-writable)"
    apply_sysctl
    apply_udev

    log "done"
    echo
    do_status
}

do_boot() {
    need_root --boot
    ensure_etc_config
    apply_sysctl
    apply_udev
}

do_status() {
    echo -n "sysctl config:             "
    if [[ ! -f "$SYSCTL_DEST" ]]; then
        echo "NOT installed"
    elif cmp -s "$SYSCTL_SRC" "$SYSCTL_DEST"; then
        echo "installed (matches repo)"
    else
        echo "installed but DIFFERS from repo"
    fi

    echo -n "udev rule (SATA LPM):      "
    if [[ ! -f "$UDEV_DEST" ]]; then
        echo "NOT installed"
    elif cmp -s "$UDEV_SRC" "$UDEV_DEST"; then
        echo "installed (matches repo)"
    else
        echo "installed but DIFFERS from repo"
    fi

    echo -n "atomic-update keep entry:  "
    [[ -f "$KEEP_DEST" ]] && echo "installed" || echo "MISSING (config lost on next OS update)"

    echo -n "boot self-heal unit:       "
    systemctl is-enabled steam-machine-power.service >/dev/null 2>&1 \
        && echo "enabled" || echo "NOT enabled"

    echo
    echo "live values:"
    printf '  %-30s %s\n' "kernel.nmi_watchdog" "$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null || echo '?')"
    printf '  %-30s %s\n' "vm.dirty_writeback_centisecs" "$(cat /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || echo '?')"

    echo
    echo "SATA link power management (ports with no disk are a no-op):"
    local h disk
    for h in /sys/class/scsi_host/host*; do
        [[ -f "$h/link_power_management_policy" ]] || continue
        # `|| true` is required here: on an empty port the glob matches nothing,
        # `ls` exits non-zero, and pipefail propagates that through the
        # assignment -- which under `set -e` silently truncated this table at
        # the first empty host.
        disk="$(ls -d "$h"/device/target*/*/block/* 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ' || true)"
        printf '  %-7s %-24s %s\n' "$(basename "$h")" \
            "$(cat "$h/link_power_management_policy")" "${disk:-(empty)}"
    done

    # LPM interacts badly with a minority of SATA SSDs. If it is going to go
    # wrong on this pair it shows up as link resets under load, and it would be
    # easy to blame the filesystem instead -- so surface it here rather than
    # leaving it for someone to find in the journal weeks later.
    local ata_errs
    ata_errs="$(journalctl -b --no-pager -k 2>/dev/null \
        | rg -c 'ata[0-9]+.*(exception Emask|failed command|hard resetting link)' || true)"
    printf '  %-32s %s\n' "ATA errors this boot:" \
        "${ata_errs:-0}${ata_errs:+  <-- investigate before trusting LPM}"

    echo
    echo "cpufreq (informational -- not managed by this subsystem):"
    printf '  %-30s %s\n' "driver"    "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo '?')"
    printf '  %-30s %s\n' "governor"  "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
    printf '  %-30s %s\n' "EPP"       "$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo '?')"
    printf '  %-30s %s\n' "cpuidle driver" "$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null || echo '?')"

    # Clamp check. powertop writes scaling_max_freq/scaling_min_freq/
    # scaling_setspeed across every core when it calibrates, and restores them
    # afterwards -- unless it exits first, in which case cores are left pinned.
    # Seen on 2026-08-03: an interactive `sudo powertop` left cpu0 and cpu3 at
    # 603 MHz while the other six went back to 5.27 GHz.
    #
    # There is no error, no log line, and no symptom until a game stutters on
    # two of eight cores. It does not survive a reboot, which makes it harder to
    # catch, not easier -- it is exactly the sort of thing that gets blamed on a
    # Proton update three days later.
    local clamped=() c cur cmax
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [[ -f "$c/scaling_max_freq" ]] || continue
        cur="$(cat "$c/scaling_max_freq")"
        cmax="$(cat "$c/cpuinfo_max_freq")"
        (( cur < cmax )) && clamped+=("$(basename "$(dirname "$c")")=$((cur / 1000))MHz")
    done
    if (( ${#clamped[@]} )); then
        echo
        warn "${#clamped[@]} core(s) CLAMPED below hardware max ($(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq) kHz):"
        warn "  ${clamped[*]}"
        warn "  usual cause: an interrupted 'powertop' calibration. Fix without a reboot:"
        warn "  SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A $0 --restore-freq"
    fi
    # scaling_cur_freq is deliberately NOT printed. On amd-pstate it is derived
    # from APERF/MPERF, which only tick in C0 -- so it reports the frequency
    # during the awake slices and is blind to halted time. At desktop idle it
    # reads ~4.1 GHz on a machine that is asleep 93% of the time, which reads as
    # "the CPU never downclocks" and is the single most misleading number on the
    # box. The residency table below is the honest answer to that question.

    echo
    echo "sleep inhibitors (a held 'block' on sleep is worth more than every"
    echo "tunable above -- see hardware/sleep/):"
    systemd-inhibit --list --no-pager 2>/dev/null \
        | awk 'NR==1 || /block/' | sed 's/^/  /' || echo "  (unavailable)"

    echo
    do_measure
}

# Put every core's frequency policy back to the hardware limits.
#
# Not part of --install or --boot on purpose. At boot the policy is already
# correct -- the kernel builds it from cpuinfo_* and nothing has had a chance to
# clamp it yet -- so a boot-time restore would be a no-op guarding a window that
# does not exist. The risk window is "someone just ran powertop", which is a
# manual event and gets a manual fix.
do_restore_freq() {
    need_root --restore-freq
    local c n=0
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [[ -f "$c/scaling_max_freq" ]] || continue
        cat "$c/cpuinfo_max_freq" > "$c/scaling_max_freq"
        cat "$c/cpuinfo_min_freq" > "$c/scaling_min_freq"
        n=$((n + 1))
    done
    log "restored hardware frequency limits on $n cores"
    echo
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [[ -f "$c/scaling_max_freq" ]] || continue
        printf '  %-6s %s MHz\n' "$(basename "$(dirname "$c")")" \
            "$(( $(cat "$c/scaling_max_freq") / 1000 ))"
    done
}

do_uninstall() {
    need_root --uninstall
    systemctl disable --now steam-machine-power.service >/dev/null 2>&1 || true
    rm -f "$SYSCTL_DEST" "$UDEV_DEST" "$KEEP_DEST" "$UNIT_DEST"
    systemctl daemon-reload

    # Same reasoning as the sysctls below: deleting the rule only stops it being
    # applied to future hosts. Put the live links back to the kernel default.
    local h
    for h in /sys/class/scsi_host/host*/link_power_management_policy; do
        [[ -w "$h" ]] && echo max_performance > "$h" 2>/dev/null || true
    done
    udevadm control --reload >/dev/null 2>&1 || true

    # Put the kernel defaults back explicitly. Deleting the sysctl file only
    # stops it being applied at the *next* boot; without this, "uninstalled"
    # would still be running with the watchdog off until then.
    sysctl -q -w kernel.nmi_watchdog=1 || warn "could not restore nmi_watchdog"
    sysctl -q -w vm.dirty_writeback_centisecs=500 || warn "could not restore dirty_writeback_centisecs"
    log "uninstalled -- kernel defaults restored, no reboot needed"
}

case "${1:-}" in
    ""|--install)   do_install ;;
    --boot)         do_boot ;;
    --status)       do_status ;;
    --restore-freq) do_restore_freq ;;
    --uninstall)    do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
