#!/usr/bin/env bash
# Install the hand-built mainline kernel that enables HDMI 2.1 FRL, giving
# 4K120 RGB 4:4:4 12-bit on the GPU's native HDMI port. See ./README.md.
#
#   ./install.sh            full install from the cached artefacts
#   ./install.sh --boot     boot-time path: reinstall whatever a SteamOS
#                           update deleted; no-op if everything is present
#   ./install.sh --status   report current state and exit
#   ./install.sh --uninstall
#   ./install.sh --cache    (re)build the cache tarball from a kernel build tree
#
# Everything authoritative lives under /home, because SteamOS replaces the
# whole rootfs slot AND the per-slot EFI partition on every A/B update.
#
# The kernel deliberately lives in /boot/frl/ rather than /boot/. GRUB's
# 10_linux globs `/boot/vmlinuz-*` (and nothing recursive), so a subdirectory
# is invisible to it and the generated grub.cfg stays byte-for-byte stock. The
# entire FRL boot path is one file on the EFI partition: custom.cfg, which
# /etc/grub.d/41_custom sources at the very end of grub.cfg.
#
# That is what makes this safe on a machine whose only console is the TV: if
# custom.cfg is missing or malformed, GRUB falls through to completely stock
# behaviour and boots the Valve kernel. There is no state in which a broken
# FRL install can prevent the stock kernel from booting.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${FRL_KERNEL_CACHE:-/home/deck/.cache/frl-kernel}"
BUILD_TREE="${FRL_BUILD_TREE:-/home/deck/kernel-frl/build72}"

KVER_FILE="$CACHE_DIR/kver"
BOOT_SUBDIR="/boot/frl"
PRESET_DEST="/etc/mkinitcpio.d/linux-frlprobe.preset"
SERVICE_DEST="/etc/systemd/system/steam-machine-kernel.service"
# /etc/systemd/system/*.service is already on SteamOS's default keep list, but
# the entry is written anyway so the intent is explicit and survives changes to
# Valve's default list. It names the specific file, never the directory --
# allowlisting a directory permanently shadows all future upstream versions.
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-kernel.conf"

MENU_ID="frl-probe"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"; }

# --- discovery ----------------------------------------------------------------

# findmnt reports no UUID for a btrfs subvolume root, so go via the device.
rootfs_uuid() {
    local dev
    dev="$(findmnt -no SOURCE / | sed 's/\[.*//')"
    [[ -n $dev ]] || die "cannot determine the rootfs device"
    blkid -s UUID -o value "$dev" 2>/dev/null || die "cannot read UUID of $dev"
}

# The EFI partition GRUB actually loaded its config from. /efi is where SteamOS
# mounts the per-slot one; fall back to a search so this does not silently write
# custom.cfg somewhere GRUB will never read it.
efi_dir() {
    local d
    for d in /efi/EFI/steamos /boot/efi/EFI/steamos /esp/EFI/steamos; do
        [[ -f "$d/grub.cfg" ]] && { echo "$d"; return; }
    done
    die "cannot find the directory holding grub.cfg"
}

cached_kver() { [[ -f $KVER_FILE ]] && cat "$KVER_FILE"; }

# --- state --------------------------------------------------------------------

kernel_installed() {
    local k="${1:-$(cached_kver)}"
    [[ -n $k ]] || return 1
    [[ -f "$BOOT_SUBDIR/vmlinuz-linux-frlprobe" ]] \
        && [[ -f "$BOOT_SUBDIR/initramfs-linux-frlprobe.img" ]] \
        && [[ -d "/usr/lib/modules/$k" ]]
}

custom_cfg_installed() {
    local cfg="$1"
    [[ -f $cfg ]] && grep -q "vmlinuz-linux-frlprobe" "$cfg" \
        && grep -q "$(rootfs_uuid)" "$cfg"
}

# --- SteamOS read-only rootfs -------------------------------------------------
RO_WAS_ENABLED=0
unlock_rootfs() {
    if steamos-readonly status 2>/dev/null | grep -q enabled; then
        RO_WAS_ENABLED=1
        log "unlocking read-only rootfs"
        steamos-readonly disable || die "could not disable steamos-readonly"
    fi
}
relock_rootfs() {
    if [[ $RO_WAS_ENABLED -eq 1 ]]; then
        log "restoring read-only rootfs"
        steamos-readonly enable || warn "could not re-enable steamos-readonly"
    fi
}

# --- cache --------------------------------------------------------------------

# Packs the built kernel into a single tarball under /home. This is what makes
# reinstalling after an A/B update cheap: no rebuild, no container, no network.
build_cache() {
    need_root
    [[ -d $BUILD_TREE ]] || die "no build tree at $BUILD_TREE (set FRL_BUILD_TREE)"

    local kver
    kver="$(cat "$BUILD_TREE/include/config/kernel.release" 2>/dev/null)" \
        || die "cannot read kernel.release from $BUILD_TREE"
    [[ -n $kver ]] || die "empty kernel version from $BUILD_TREE"

    [[ -d "/usr/lib/modules/$kver" ]] \
        || die "modules for $kver are not installed; run a full install first"

    log "packing $kver into the cache"
    mkdir -p "$CACHE_DIR"

    local stage
    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' RETURN

    mkdir -p "$stage/boot" "$stage/usr/lib/modules"
    cp "$BUILD_TREE/arch/x86/boot/bzImage" "$stage/boot/vmlinuz-linux-frlprobe"
    cp -a "/usr/lib/modules/$kver" "$stage/usr/lib/modules/"
    # The build symlink points into the build tree; it is not part of the
    # runtime artefact and would be a dangling link after a restore.
    rm -f "$stage/usr/lib/modules/$kver/build"

    # -3, not -19: the modules are already individually zstd-compressed, so a
    # high level costs minutes and saves almost nothing.
    tar -C "$stage" -c boot usr | zstd -q -T0 -3 > "$CACHE_DIR/kernel.tar.zst.new"
    mv "$CACHE_DIR/kernel.tar.zst.new" "$CACHE_DIR/kernel.tar.zst"
    echo "$kver" > "$KVER_FILE"

    chown -R deck:deck "$CACHE_DIR"
    log "cached $(du -h "$CACHE_DIR/kernel.tar.zst" | cut -f1) at $CACHE_DIR"
}

# --- install ------------------------------------------------------------------

deploy_kernel() {
    local kver="$1"
    log "restoring kernel $kver from cache"
    mkdir -p "$BOOT_SUBDIR"
    tar -C / --zstd -xf "$CACHE_DIR/kernel.tar.zst" boot usr
    # The tarball carries boot/vmlinuz-*; move it into the subdirectory so
    # GRUB's 10_linux never sees it.
    if [[ -f /boot/vmlinuz-linux-frlprobe ]]; then
        mv /boot/vmlinuz-linux-frlprobe "$BOOT_SUBDIR/vmlinuz-linux-frlprobe"
    fi
    depmod "$kver"
}

install_preset_file() {
    install -Dm644 "$REPO_DIR/mkinitcpio.d/linux-frlprobe.preset" "$PRESET_DEST"
}

# Kept separate from install_preset_file on purpose. An earlier version folded
# the two together and gated the whole thing on the initramfs being absent, so
# a run where only the preset had been deleted restored nothing -- caught by
# deleting the preset and watching --status still report it missing.
regen_initramfs() {
    local kver="$1"
    log "generating initramfs for $kver"
    # mkinitcpio resolves the kernel version from the image itself, so the
    # preset's ALL_kver points at the vmlinuz in /boot/frl.
    mkinitcpio -p linux-frlprobe 2>&1 | grep -Ei 'error|image generation successful' \
        | grep -v 'steamdeck\|blake2b_generic' || true
    [[ -f "$BOOT_SUBDIR/initramfs-linux-frlprobe.img" ]] \
        || die "mkinitcpio produced no initramfs"
}

install_grub_entry() {
    local efi uuid cfg
    efi="$(efi_dir)"
    uuid="$(rootfs_uuid)"
    cfg="$efi/custom.cfg"

    log "writing $cfg (rootfs UUID $uuid)"
    sed -e "s|@UUID@|$uuid|g" -e "s|@MENU_ID@|$MENU_ID|g" \
        "$REPO_DIR/grub/custom.cfg.in" > "$cfg.new"
    chmod 700 "$cfg.new"
    mv "$cfg.new" "$cfg"

    # grub.cfg is NOT regenerated: the kernel lives outside /boot/vmlinuz-*, so
    # 10_linux has nothing to pick up and the stock config is already correct.
    grep -q 'vmlinuz-linux-frlprobe' "$efi/grub.cfg" \
        && warn "grub.cfg references the FRL kernel -- it should not; run update-grub"
    return 0
}

install_service() {
    install -Dm644 "$REPO_DIR/systemd/steam-machine-kernel.service" "$SERVICE_DEST"
    install -Dm644 "$REPO_DIR/atomic-update.conf.d/steam-machine-kernel.conf" "$KEEP_DEST"
    systemctl daemon-reload
    systemctl enable steam-machine-kernel.service >/dev/null 2>&1 \
        || warn "could not enable steam-machine-kernel.service"
}

do_install() {
    need_root
    local kver
    kver="$(cached_kver)" || true
    [[ -n ${kver:-} ]] || die "no cached kernel; run './install.sh --cache' first"
    [[ -f "$CACHE_DIR/kernel.tar.zst" ]] || die "cache tarball missing at $CACHE_DIR"

    unlock_rootfs
    trap relock_rootfs EXIT

    kernel_installed "$kver" || deploy_kernel "$kver"
    install_preset_file
    regen_initramfs "$kver"
    install_grub_entry
    install_service

    log "done -- '$MENU_ID' is now the default boot entry, with a 10s menu"
}

# Boot-time self-heal. Runs before any fast-path exit so a SteamOS update that
# wiped the rootfs and the EFI partition is repaired on the next boot.
do_boot() {
    need_root
    local kver
    kver="$(cached_kver)" || true
    if [[ -z ${kver:-} || ! -f "$CACHE_DIR/kernel.tar.zst" ]]; then
        warn "no cached kernel -- nothing to restore"
        return 0
    fi

    local efi need=0
    efi="$(efi_dir)"

    kernel_installed "$kver" || need=1
    [[ -f $PRESET_DEST ]] || need=1
    [[ -f "$BOOT_SUBDIR/initramfs-linux-frlprobe.img" ]] || need=1
    custom_cfg_installed "$efi/custom.cfg" || need=1
    [[ -f $SERVICE_DEST ]] || need=1
    [[ -f $KEEP_DEST ]] || need=1

    if [[ $need -eq 0 ]]; then
        log "FRL kernel $kver intact -- nothing to do"
        return 0
    fi

    log "reinstalling after a SteamOS update"
    unlock_rootfs
    trap relock_rootfs EXIT

    kernel_installed "$kver" || deploy_kernel "$kver"
    install_preset_file
    [[ -f "$BOOT_SUBDIR/initramfs-linux-frlprobe.img" ]] || regen_initramfs "$kver"
    install_grub_entry
    install_service
    log "restored -- '$MENU_ID' will be the default at the next boot"
}

do_status() {
    local kver efi
    kver="$(cached_kver)" || true
    efi="$(efi_dir 2>/dev/null || echo '?')"

    echo "cached kernel      : ${kver:-<none>}"
    echo "cache tarball      : $( [[ -f "$CACHE_DIR/kernel.tar.zst" ]] \
        && du -h "$CACHE_DIR/kernel.tar.zst" | cut -f1 || echo '<missing>')"
    echo "running kernel     : $(uname -r)"
    echo "vmlinuz installed  : $( [[ -f "$BOOT_SUBDIR/vmlinuz-linux-frlprobe" ]] && echo yes || echo NO)"
    echo "initramfs installed: $( [[ -f "$BOOT_SUBDIR/initramfs-linux-frlprobe.img" ]] && echo yes || echo NO)"
    echo "modules installed  : $( [[ -n ${kver:-} && -d "/usr/lib/modules/$kver" ]] && echo yes || echo NO)"
    echo "mkinitcpio preset  : $( [[ -f $PRESET_DEST ]] && echo yes || echo NO)"
    echo "grub custom.cfg    : $( [[ -f "$efi/custom.cfg" ]] && echo "yes ($efi/custom.cfg)" || echo NO)"
    echo "boot service       : $(systemctl is-enabled steam-machine-kernel.service 2>/dev/null || echo NO)"
    echo "grub.cfg is stock  : $( grep -q 'vmlinuz-linux-frlprobe' "$efi/grub.cfg" 2>/dev/null \
        && echo 'NO -- FRL kernel leaked into it' || echo yes)"

    if [[ $(uname -r) == "${kver:-}" ]]; then
        echo
        echo "FRL link state:"
        echo "  dcfeaturemask    : $(cat /sys/module/amdgpu/parameters/dcfeaturemask 2>/dev/null) (1026 == 0x402)"
        local dtn=/sys/kernel/debug/dri/0/amdgpu_dm_dtn_log
        if [[ -r $dtn ]]; then
            # The HPO block is a header, one data row, then a blank line.
            grep -A1 '^HPO:' "$dtn" | tail -1 | sed 's/^ */  HPO              : /'
        else
            echo "  (run as root for the link state)"
        fi
    fi
}

do_uninstall() {
    need_root
    [[ $(uname -r) == "$(cached_kver 2>/dev/null)" ]] \
        && die "currently running the FRL kernel -- reboot into the stock kernel first"

    unlock_rootfs
    trap relock_rootfs EXIT

    systemctl disable --now steam-machine-kernel.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_DEST" "$KEEP_DEST" "$PRESET_DEST"
    systemctl daemon-reload

    local kver efi
    kver="$(cached_kver)" || true
    [[ -n ${kver:-} ]] && rm -rf "/usr/lib/modules/$kver"
    rm -rf "$BOOT_SUBDIR"

    efi="$(efi_dir)"
    rm -f "$efi/custom.cfg"

    # Stock GRUB behaviour is restored the moment custom.cfg is gone: grub.cfg
    # was never modified, so there is nothing to regenerate.
    grep -q 'vmlinuz-linux-neptune' "$efi/grub.cfg" \
        || die "stock kernel absent from grub.cfg -- do NOT reboot; investigate"

    log "removed. The cache at $CACHE_DIR is kept -- delete it manually to reclaim space."
}

case "${1:---install}" in
    --install|"") do_install ;;
    --boot)       do_boot ;;
    --cache)      build_cache ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    -h|--help)    sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ;;
    *)            die "unknown option: $1 (try --help)" ;;
esac
