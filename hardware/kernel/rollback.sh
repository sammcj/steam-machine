#!/usr/bin/env bash
# Removes the 7.2-rc6 "linux-frlprobe" test kernel and every change made for it,
# returning the machine to stock SteamOS boot behaviour.
#
# Safe to run from a normal 6.16 boot. Refuses to run while the probe kernel is
# the running kernel, since it would delete the modules out from under it.
set -euo pipefail

KVER=7.2.0-rc6-frlprobe

die() { echo "error: $*" >&2; exit 1; }

[[ $(uname -r) == "$KVER" ]] && die "currently running $KVER -- reboot into the stock kernel first"
[[ $EUID -eq 0 ]] || die "run with sudo"

ro_was_enabled=false
if steamos-readonly status 2>/dev/null | grep -q enabled; then
    ro_was_enabled=true
    steamos-readonly disable
fi

echo "removing kernel and modules"
rm -rf "/usr/lib/modules/$KVER"
rm -f /boot/vmlinuz-linux-frlprobe
rm -f /boot/initramfs-linux-frlprobe.img /boot/initramfs-linux-frlprobe-fallback.img
rm -f /etc/mkinitcpio.d/linux-frlprobe.preset

echo "removing boot menu changes"
rm -f /etc/default/grub.d/70-frlprobe-boot.cfg
rm -f /efi/EFI/steamos/custom.cfg

echo "regenerating grub.cfg"
update-grub >/dev/null 2>&1 || die "update-grub failed -- do NOT reboot; investigate first"

# Stock behaviour is GRUB_DEFAULT=0 with the steamenv block's timeout=0, i.e.
# straight to the top-level SteamOS entry with no menu.
grep -q 'vmlinuz-linux-frlprobe' /efi/EFI/steamos/grub.cfg \
    && die "grub.cfg still references the probe kernel -- investigate before rebooting"

echo "verifying the stock kernel is still bootable"
[[ -f /boot/vmlinuz-linux-neptune-616-drm-exec ]] \
    || die "stock kernel missing -- do NOT reboot"
[[ -f /boot/initramfs-linux-neptune-616-drm-exec.img ]] \
    || die "stock initramfs missing -- do NOT reboot"
grep -q 'vmlinuz-linux-neptune-616-drm-exec' /efi/EFI/steamos/grub.cfg \
    || die "stock kernel absent from grub.cfg -- do NOT reboot"

$ro_was_enabled && steamos-readonly enable

echo
echo "rolled back. /home/deck/kernel-frl still holds the source and build tree;"
echo "delete it manually to reclaim the disk space."
