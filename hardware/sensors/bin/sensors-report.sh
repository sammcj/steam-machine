#!/usr/bin/env bash
# Full inventory of what this machine can actually measure: every hwmon chip,
# which driver provides it, which physical device it belongs to, and every
# reading it exposes.
#
# Use this to check coverage after a kernel change, or to work out which
# drivetemp instance is which SSD (SATA enumeration is not stable across
# reboots, so scsi-0 and scsi-1 can swap).
#
#   ./sensors-report.sh          human-readable inventory
#   ./sensors-report.sh --raw    add the raw sysfs values behind each reading
set -euo pipefail

RAW=0
[[ "${1:-}" == "--raw" ]] && RAW=1

c_hdr=$'\033[1;34m'; c_dim=$'\033[2m'; c_warn=$'\033[1;33m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_hdr=""; c_dim=""; c_warn=""; c_off=""; }

hdr() { printf '%s==> %s%s\n' "$c_hdr" "$*" "$c_off"; }

# Resolve an hwmon directory to something physically meaningful.
describe_device() {
    local h=$1 dev real
    dev="$h/device"
    [[ -e "$dev" ]] || { echo "(virtual)"; return; }
    real="$(readlink -f "$dev")"

    # SATA/SCSI: walk to the block device and read its model.
    local blk
    blk="$(find "$real" -maxdepth 3 -path '*/block/*' -name 'sd*' -printf '%f\n' 2>/dev/null | head -1)"
    if [[ -n "$blk" ]]; then
        echo "/dev/$blk -- $(cat "/sys/block/$blk/device/model" 2>/dev/null | xargs)"
        return
    fi
    # NVMe
    if [[ "$real" == *nvme* ]]; then
        local n; n="$(basename "$real")"
        echo "$n -- $(cat "/sys/class/nvme/$n/model" 2>/dev/null | xargs || true)"
        return
    fi
    # PCI: use the modalias-free short form
    if [[ -f "$real/vendor" && -f "$real/device" ]]; then
        echo "PCI $(basename "$real") [$(cat "$real/vendor"):$(cat "$real/device")]"
        return
    fi
    echo "$c_dim${real#/sys/devices/}$c_off"
}

hdr "kernel"
printf '  %s\n' "$(uname -r)"
printf '  cmdline: acpi_enforce_resources=%s\n' \
    "$(grep -o 'acpi_enforce_resources=[a-z]*' /proc/cmdline | cut -d= -f2 || echo 'strict (default)')"

hdr "hwmon chips"
for h in /sys/class/hwmon/hwmon*; do
    name="$(cat "$h/name" 2>/dev/null || echo '?')"
    drv="(none)"
    [[ -e "$h/device/driver" ]] && drv="$(basename "$(readlink -f "$h/device/driver")")"
    printf '  %-16s driver=%-14s %s\n' "$name" "$drv" "$(describe_device "$h")"
    if [[ $RAW -eq 1 ]]; then
        for f in "$h"/{temp,fan,in,power,pwm}*_input; do
            [[ -e "$f" ]] || continue
            printf '      %s%-14s %s%s\n' "$c_dim" "$(basename "$f")" "$(cat "$f")" "$c_off"
        done
    fi
done

hdr "i2c / SMBus adapters"
if i2cdetect -l 2>/dev/null | grep -qi piix4; then
    i2cdetect -l | grep -i piix4 | sed 's/^/  /'
else
    printf '  %sno piix4 adapters -- FCH SMBus is not available%s\n' "$c_warn" "$c_off"
    printf '  %s(needs acpi_enforce_resources=lax; see ../README.md)%s\n' "$c_dim" "$c_off"
fi

hdr "DDR5 SPD hubs claimed by spd5118"
if compgen -G "/sys/bus/i2c/drivers/spd5118/*-00*" >/dev/null 2>&1; then
    for d in /sys/bus/i2c/drivers/spd5118/*-00*; do
        printf '  %s\n' "$(basename "$d")"
    done
    printf '  %sthese addresses now return EBUSY to userspace i2c -- do not unbind%s\n' \
        "$c_dim" "$c_off"
else
    printf '  %snone -- DIMM temperatures unavailable%s\n' "$c_warn" "$c_off"
fi

hdr "readings"
sensors

hdr "coverage gaps"
gaps=0
compgen -G "/sys/bus/i2c/drivers/spd5118/*-00*" >/dev/null 2>&1 \
    || { echo "  - DDR5 DIMM temps (no SMBus / spd5118 unbound)"; gaps=1; }
grep -qi it8696 /sys/class/hwmon/*/name 2>/dev/null \
    || { echo "  - fan RPM, Vcore, VRM temp (it87 not loaded)"; gaps=1; }
grep -qi drivetemp /sys/class/hwmon/*/name 2>/dev/null \
    || { echo "  - SATA SSD temps (drivetemp not loaded)"; gaps=1; }
[[ $gaps -eq 0 ]] && echo "  none -- full coverage"
