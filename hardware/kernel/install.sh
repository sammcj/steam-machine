#!/usr/bin/env bash
# Install the hand-built mainline kernel that enables HDMI 2.1 FRL, giving
# 4K120 RGB 4:4:4 12-bit on the GPU's native HDMI port. See ./README.md.
#
#   ./install.sh            full install from the cached artefacts
#   ./install.sh --boot     boot-time path: reinstall whatever a SteamOS
#                           update deleted; no-op if everything is present
#   ./install.sh --status   report current state and exit
#   ./install.sh --uninstall
#   ./install.sh --cache    save the INSTALLED kernel and modules into the
#                           cache tarball on /home
#
# About --cache, because getting this wrong is silent: the tarball under /home
# is the ONLY thing that survives a SteamOS A/B update. --boot restores the
# kernel by extracting it, so whatever is in /usr/lib/modules at the moment you
# run --cache is exactly what comes back -- and anything installed by hand
# afterwards is lost at the next OS update with no symptom beyond the feature
# quietly not working. --status warns when the two have drifted apart.
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
# Blacklists mt7921e. Mainline 7.2 binds it to the onboard MT7902, whose Wi-Fi
# firmware does not exist, and its .shutdown handler then hangs the machine at
# power-off. Specific to this kernel: Valve's 6.16 never matches the device.
# See modprobe.d/mt7902-wifi.conf for the full chain.
MODPROBE_DEST="/etc/modprobe.d/mt7902-wifi.conf"
# Switches to a text VT at the start of shutdown. Without it, a power-off begun
# while the Gamescope session still owns the display hangs -- see README.md.
VT_UNIT="steam-machine-shutdown-vt.service"
VT_DEST="/etc/systemd/system/$VT_UNIT"

MENU_ID="frl-probe"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# need_root() now comes from lib/elevate.sh -- it elevates before dying.
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

# The UUID goes into a local first. Inlining $(rootfs_uuid) would run die() in a
# subshell, so a failure to read it would leave `grep -q ""` -- which matches
# anything, and would declare a stale-UUID custom.cfg valid.
custom_cfg_installed() {
    local cfg="$1" uuid
    [[ -f $cfg ]] || return 1
    uuid="$(rootfs_uuid)"
    grep -q "vmlinuz-linux-frlprobe" "$cfg" && grep -q "$uuid" "$cfg"
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
    # --transform rewrites boot/ to boot/frl/ during extraction. An earlier
    # version extracted to /boot/vmlinuz-* and moved it afterwards; a crash in
    # that window left a vmlinuz in /boot proper, which 10_linux globs into
    # grub.cfg -- with no matching initramfs, and version-sorted above the stock
    # kernel. /boot itself is never written to now.
    tar -C / --zstd -xf "$CACHE_DIR/kernel.tar.zst" \
        --transform 's|^boot/|boot/frl/|' boot usr
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
    #
    # Its exit status is captured rather than piped into grep. Piping and
    # swallowing with `|| true` meant a failed run was indistinguishable from a
    # good one, and the only check was that *an* image existed -- which a stale
    # image from the previous kernel satisfies. That boots the default entry
    # into an initramfs whose modules will not load.
    # mkinitcpio always exits 1 here, because the SteamOS hooks ask for modules
    # that only exist in Valve's kernel (steamdeck, steamdeck_hwmon,
    # leds_steamdeck, extcon_steamdeck) plus blake2b_generic, which mainline
    # builds in rather than as a module. Those are expected and harmless -- the
    # running kernel booted from an image with exactly these errors. So the exit
    # status alone cannot be the test: filter the known-benign lines and fail on
    # anything left, then require both images to be newer than this run.
    local out rc=0 marker unexpected
    marker="$(mktemp)"
    out="$(mkinitcpio -p linux-frlprobe 2>&1)" || rc=$?

    unexpected="$(printf '%s\n' "$out" | grep -E '^==> ERROR' \
        | grep -Ev "module not found: '(blake2b_generic|steamdeck|steamdeck_hwmon|leds_steamdeck|extcon_steamdeck)'" \
        || true)"
    if [[ -n $unexpected ]]; then
        printf '%s\n' "$unexpected" >&2
        rm -f "$marker"
        die "mkinitcpio reported errors beyond the expected missing Deck modules (exit $rc)"
    fi

    local img
    for img in "$BOOT_SUBDIR/initramfs-linux-frlprobe.img" \
               "$BOOT_SUBDIR/initramfs-linux-frlprobe-fallback.img"; do
        [[ -f $img ]] || { rm -f "$marker"; die "mkinitcpio produced no $img"; }
        [[ $img -nt $marker ]] || { rm -f "$marker"; die "$img was not regenerated (stale image)"; }
    done
    rm -f "$marker"
    log "initramfs regenerated (mkinitcpio exit $rc, expected Deck-module errors only)"
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
    install -Dm644 "$REPO_DIR/modprobe.d/mt7902-wifi.conf" "$MODPROBE_DEST"
    install -Dm644 "$REPO_DIR/systemd/$VT_UNIT" "$VT_DEST"
    systemctl daemon-reload
    systemctl enable steam-machine-kernel.service >/dev/null 2>&1 \
        || warn "could not enable steam-machine-kernel.service"
    systemctl enable "$VT_UNIT" >/dev/null 2>&1 \
        || warn "could not enable $VT_UNIT -- power-off may hang"
}

do_install() {
    need_root
    local kver
    kver="$(cached_kver)" || true
    [[ -n ${kver:-} ]] || die "no cached kernel; run './install.sh --cache' first"
    [[ -f "$CACHE_DIR/kernel.tar.zst" ]] || die "cache tarball missing at $CACHE_DIR"

    unlock_rootfs
    trap relock_rootfs EXIT

    # Unconditional, NOT `kernel_installed || deploy_kernel`. CONFIG_LOCALVERSION
    # is unchanged across rebuilds, so a new build has the same release string as
    # the old one and kernel_installed() -- which only tests for existence --
    # would report the stale files as fine. The documented rebuild flow (--cache
    # then --install) would then boot the OLD vmlinuz against the NEW modules:
    # same vermagic, so modprobe raises nothing, and the structures disagree.
    # That entry is the default, so the failure lands on an unattended boot.
    # Extracting ~180 MB again is cheap next to that.
    deploy_kernel "$kver"
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

    # First, and deliberately ahead of every early return below.
    #
    # /etc/modprobe.d is not on SteamOS's keep list, so an A/B update deletes
    # mt7902-wifi.conf and the very next power-off hangs the machine with no
    # symptom until someone tries to shut it down. It also needs no rootfs
    # unlock -- /etc is an overlayfs whose upper layer lives in /var -- and no
    # cached kernel, so there is nothing to gate it behind.
    #
    # Restored by content, not just existence: a half-written file from an
    # interrupted update would pass a -f test and still not blacklist anything.
    if [[ -f "$REPO_DIR/modprobe.d/mt7902-wifi.conf" ]] \
       && ! cmp -s "$REPO_DIR/modprobe.d/mt7902-wifi.conf" "$MODPROBE_DEST"; then
        install -Dm644 "$REPO_DIR/modprobe.d/mt7902-wifi.conf" "$MODPROBE_DEST" \
            && log "restored $MODPROBE_DEST (mt7921e blacklist)" \
            || warn "could not restore $MODPROBE_DEST -- power-off will hang"
    fi

    # Same reasoning for the shutdown VT unit. /etc/systemd/system/*.service IS
    # on Valve's default keep list, so this is belt-and-braces rather than the
    # load-bearing copy -- but it costs one cmp and the failure mode it covers
    # (a hung power-off) is the one this whole subsystem just spent three days
    # on. Re-enabled too: the .wants symlink is separately losable.
    if [[ -f "$REPO_DIR/systemd/$VT_UNIT" ]] \
       && ! cmp -s "$REPO_DIR/systemd/$VT_UNIT" "$VT_DEST"; then
        install -Dm644 "$REPO_DIR/systemd/$VT_UNIT" "$VT_DEST" \
            && log "restored $VT_DEST" \
            || warn "could not restore $VT_DEST -- power-off may hang"
        systemctl daemon-reload
    fi
    systemctl is-enabled --quiet "$VT_UNIT" 2>/dev/null \
        || systemctl enable "$VT_UNIT" >/dev/null 2>&1 \
        || warn "could not enable $VT_UNIT -- power-off may hang"

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
    # The fallback image too. custom.cfg has a menuentry pointing at it, and the
    # entire point of that entry is being reachable when the default image is the
    # thing that is broken -- so a missing fallback is exactly the case where
    # nothing else will save you.
    [[ -f "$BOOT_SUBDIR/initramfs-linux-frlprobe-fallback.img" ]] || need=1
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
    if [[ ! -f "$BOOT_SUBDIR/initramfs-linux-frlprobe.img" \
       || ! -f "$BOOT_SUBDIR/initramfs-linux-frlprobe-fallback.img" ]]; then
        regen_initramfs "$kver"
    fi
    install_grub_entry
    install_service
    log "restored -- '$MENU_ID' will be the default at the next boot"
}

do_status() {
    local kver efi
    kver="$(cached_kver)" || true
    # `|| echo '?'` inside the substitution never fires: efi_dir ends in die,
    # which exits the subshell outright, so the `||` is never reached and the
    # assignment fails under `set -e`. The ESP is 0700 root, so that killed the
    # whole of --status for an unprivileged run -- no output, exit 1.
    efi="$(efi_dir 2>/dev/null)" || efi='?'

    echo "cached kernel      : ${kver:-<none>}"
    echo "cache tarball      : $( [[ -f "$CACHE_DIR/kernel.tar.zst" ]] \
        && du -h "$CACHE_DIR/kernel.tar.zst" | cut -f1 || echo '<missing>')"
    echo "running kernel     : $(uname -r)"
    echo "vmlinuz installed  : $( [[ -f "$BOOT_SUBDIR/vmlinuz-linux-frlprobe" ]] && echo yes || echo NO)"
    echo "initramfs installed: $( [[ -f "$BOOT_SUBDIR/initramfs-linux-frlprobe.img" ]] && echo yes || echo NO)"
    echo "modules installed  : $( [[ -n ${kver:-} && -d "/usr/lib/modules/$kver" ]] && echo yes || echo NO)"
    echo "mkinitcpio preset  : $( [[ -f $PRESET_DEST ]] && echo yes || echo NO)"
    # Checks the UUID too, not just existence: a custom.cfg left over from the
    # other A/B slot points `search --fs-uuid` at a filesystem that is not there.
    # With no readable ESP there is nothing to judge; saying NO would be a lie
    # that reads as "the boot entry is gone".
    echo "grub custom.cfg    : $( [[ $efi == '?' ]] && echo '? -- ESP is 0700 root (run as root)' \
        || { custom_cfg_installed "$efi/custom.cfg" 2>/dev/null \
        && echo "yes ($efi/custom.cfg)" \
        || { [[ -f "$efi/custom.cfg" ]] && echo 'STALE -- wrong UUID or no kernel line' || echo NO; }; })"
    echo "boot service       : $(systemctl is-enabled steam-machine-kernel.service 2>/dev/null || echo NO)"
    # Has anything been installed into the module tree since the cache was
    # built? If so it is NOT protected: a SteamOS update restores the tarball
    # and silently drops it. This caught the hand-installed hid-steam backport.
    if [[ -n ${kver:-} && -d "/usr/lib/modules/$kver" && -f "$CACHE_DIR/kernel.tar.zst" ]]; then
        newest="$(find "/usr/lib/modules/$kver" -newer "$CACHE_DIR/kernel.tar.zst" -type f -printf '%P\n' 2>/dev/null | head -3)"
        if [[ -n $newest ]]; then
            echo "cache freshness    : STALE -- modules changed since the cache was built."
            echo "                     These would be LOST at the next OS update:"
            printf '                       %s\n' $newest
            echo "                     Fix: sudo ./install.sh --cache"
        else
            echo "cache freshness    : current (cache is newer than every installed module)"
        fi
    fi
    # Reported separately from "installed", because the file being present is
    # not the same as it having taken effect: it only applies from the next
    # boot, and a currently-bound mt7921e still hangs this session's power-off.
    echo "shutdown VT unit   : $(systemctl is-enabled "$VT_UNIT" 2>/dev/null || echo 'NO -- power-off may hang')"
    echo "mt7921e blacklist  : $( [[ -f $MODPROBE_DEST ]] && echo yes || echo 'NO -- power-off will hang')"
    echo "mt7921e bound now  : $( [[ -e /sys/bus/pci/drivers/mt7921e/0000:08:00.0 ]] \
        && echo 'YES -- this boot will still hang at power-off' || echo no)"
    # An unreadable grub.cfg must not read as "stock": grep fails the same way
    # for "no match" and "cannot open the file".
    if [[ ! -r "$efi/grub.cfg" ]]; then
        echo "grub.cfg is stock  : ? -- cannot read $efi/grub.cfg (run as root)"
    elif grep -q 'vmlinuz-linux-frlprobe' "$efi/grub.cfg"; then
        echo "grub.cfg is stock  : NO -- FRL kernel leaked into it"
    else
        echo "grub.cfg is stock  : yes"
    fi

    if [[ $(uname -r) == "${kver:-}" ]]; then
        echo
        echo "FRL link state:"
        echo "  dcfeaturemask    : $(cat /sys/module/amdgpu/parameters/dcfeaturemask 2>/dev/null) (1026 == 0x402)"
        # Worth showing because the VRR patches are hand-ported off an unmerged
        # posting: if a rebuild silently drops them, this is where it shows.
        local vrr=/sys/kernel/debug/dri/0/HDMI-A-1/vrr_range
        if [[ -r $vrr ]]; then
            echo "  vrr_range        : $(tr '\n' ' ' < "$vrr" | sed 's/  */ /g;s/ $//') (Min: 0 Max: 0 == VRR patches missing)"
        fi
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

    # Order matters, and it is the reverse of install: the boot entry goes
    # first, the payload it points at second. Removing the kernel first would
    # leave the machine's *default* entry referencing a deleted file for the
    # rest of this function -- and efi_dir() can die() -- which is precisely the
    # state `set fallback` exists to rescue. Do not reorder.
    local efi kver
    efi="$(efi_dir)"

    # Stock GRUB behaviour is restored the moment custom.cfg is gone: grub.cfg
    # was never modified, so there is nothing to regenerate. Checked before
    # anything is deleted.
    grep -q 'vmlinuz-linux-neptune' "$efi/grub.cfg" \
        || die "stock kernel absent from grub.cfg -- refusing to uninstall; investigate"

    rm -f "$efi/custom.cfg"
    sync

    systemctl disable --now steam-machine-kernel.service >/dev/null 2>&1 || true
    # MODPROBE_DEST goes too: uninstalling means going back to the stock Valve
    # kernel, which never binds the MT7902 in the first place, so the blacklist
    # is pointless there -- and leaving it behind would silently deny Wi-Fi to
    # any future kernel that ships working MT7902 firmware.
    systemctl disable --now "$VT_UNIT" >/dev/null 2>&1 || true
    rm -f "$SERVICE_DEST" "$KEEP_DEST" "$PRESET_DEST" "$MODPROBE_DEST" "$VT_DEST"
    systemctl daemon-reload

    kver="$(cached_kver)" || true
    [[ -n ${kver:-} ]] && rm -rf "/usr/lib/modules/$kver"
    rm -rf "$BOOT_SUBDIR"

    log "removed. The cache at $CACHE_DIR is kept -- delete it manually to reclaim space."
}

case "${1:---install}" in
    --install|"") do_install ;;
    --boot)       do_boot ;;
    --cache)      build_cache ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    -h|--help)    sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ;;
    *)            die "unknown option: $1 (try --help)" ;;
esac
