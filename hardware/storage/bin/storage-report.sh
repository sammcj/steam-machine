#!/usr/bin/env bash
# Health and capacity of the BTRFS RAID1 game library.
#
# The interesting line is "device stats" -- btrfs counts read/write/flush/
# corruption/generation errors per device and they persist across reboots. On a
# healthy mirror every counter is 0. A rising corruption count on one device,
# with the array still reading fine, means the mirror is doing its job and that
# disk is on the way out.
set -euo pipefail

MOUNT_POINT="${GAMES_MOUNT:-/home/deck/SATA}"

c_hdr=$'\033[1;34m'; c_ok=$'\033[1;32m'; c_bad=$'\033[1;31m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_hdr=""; c_ok=""; c_bad=""; c_off=""; }
hdr() { printf '%s==> %s%s\n' "$c_hdr" "$*" "$c_off"; }

SUDO=()
[[ $EUID -ne 0 ]] && SUDO=(sudo -A)
export SUDO_ASKPASS="${SUDO_ASKPASS:-/usr/bin/ksshaskpass}"

if ! grep -q " $MOUNT_POINT btrfs " /proc/mounts; then
    printf '%sNOT MOUNTED%s at %s\n' "$c_bad" "$c_off" "$MOUNT_POINT"
    echo "  try: sudo -A mount $MOUNT_POINT"
    echo "  if a disk is missing, a degraded mount is manual and deliberate:"
    echo "    sudo -A mount -o degraded,ro UUID=<uuid> $MOUNT_POINT"
    exit 1
fi

hdr "mount"
grep " $MOUNT_POINT btrfs " /proc/mounts | awk '{print "  "$1" -> "$2"\n  "$4}' | tr ',' '\n  '

hdr "capacity"
"${SUDO[@]}" btrfs filesystem usage -T "$MOUNT_POINT" | sed 's/^/  /'

hdr "device stats (all zeroes = healthy)"
bad=0
while read -r line; do
    val="${line##* }"
    if [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]]; then
        printf '  %s%s%s\n' "$c_bad" "$line" "$c_off"; bad=1
    else
        printf '  %s\n' "$line"
    fi
done < <("${SUDO[@]}" btrfs device stats "$MOUNT_POINT")
[[ $bad -eq 0 ]] && printf '  %sno errors recorded%s\n' "$c_ok" "$c_off"

hdr "last scrub"
"${SUDO[@]}" btrfs scrub status "$MOUNT_POINT" | sed 's/^/  /'

hdr "compression"
if command -v compsize >/dev/null 2>&1; then
    "${SUDO[@]}" compsize "$MOUNT_POINT" | sed 's/^/  /'
else
    echo "  compsize not installed -- for actual compression ratios:"
    echo "    sudo -A pacman -Sy --needed --noconfirm compsize"
fi

hdr "maintenance timers"
for t in "btrfs-scrub@$(systemd-escape -p "$MOUNT_POINT").timer" fstrim.timer steam-machine-dedupe.timer; do
    printf '  %-40s %-10s next: %s\n' "$t" \
        "$(systemctl is-enabled "$t" 2>&1)" \
        "$(systemctl show -p NextElapseUSecRealtime --value "$t" 2>/dev/null || echo '-')"
done
