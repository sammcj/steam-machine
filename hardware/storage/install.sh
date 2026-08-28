#!/usr/bin/env bash
# Mount the BTRFS RAID1 mirror (2x Crucial MX500) as a secondary game library
# that Steam can use, with SSD-appropriate options and periodic maintenance.
#
#   ./install.sh              full setup (mount point, fstab, mount, timers)
#   ./install.sh --no-dedupe  skip the monthly dedupe timer
#   ./install.sh --status     report current state and exit
#   ./install.sh --boot       boot-time path: restore the fstab entry, udev rule
#                             and dedupe timer if a SteamOS update dropped them.
#                             None is on the default /etc keep list
#   ./install.sh --uninstall  unmount and remove config (never touches data)
#
# Registering the mount as a Steam library is a separate, one-time step --
# see bin/steam-add-library.sh, which has to be run with Steam closed.
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
_l=$(_lib) && source "$_l" && source "${_l%/*}/rootfs.sh"


REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hardcoded rather than resolved from the label: a label is mutable and could
# collide with a USB drive, and mounting the wrong filesystem here would let
# Steam write games into it. `btrfs filesystem show SATA` to confirm -- and note
# the label was already renamed once (games -> SATA), which is the point.
FS_UUID="${GAMES_UUID:-ae6c1cf6-9aa0-42d6-8745-28e5d05a12dd}"
MOUNT_POINT="${GAMES_MOUNT:-/home/deck/SATA}"
SUBVOL="@SATA"

# Keeps udisks from offering the array as removable media, which is how it ends
# up mounted a second time (top-level subvolume, /run/media/deck/<label>) with
# every file reachable by two paths. The rule is rendered from the UUID above
# rather than carrying its own copy -- one source of truth.
UDEV_SRC="$REPO_DIR/udev.rules.d/60-steam-machine-storage.rules"
UDEV_DEST="/etc/udev/rules.d/60-steam-machine-storage.rules"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-storage.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-storage.conf"
BOOT_UNIT="steam-machine-storage.service"

# noatime        games do enormous numbers of reads; atime writes are pure wear
# compress=zstd:1  cheapest useful level. Btrfs skips incompressible extents by
#                itself, so precompressed game assets cost ~nothing
# discard=async  queued TRIM. The right choice on btrfs -- synchronous `discard`
#                stalls on delete, and fstrim.timer alone leaves stale blocks
# space_cache=v2 free space tree; the old v1 cache is a known scaling problem
# commit=120     4x the default 30s between commits. Fewer metadata writes on a
#                volume that is overwhelmingly reads. Widens the power-cut loss
#                window to 2 min, which is the right trade for replaceable game
#                installs -- do NOT copy this to a volume holding save data
# nofail         a missing/broken mirror must not drop the machine to an
#                emergency shell it cannot display on a TV
MOUNT_OPTS="noatime,compress=zstd:1,discard=async,space_cache=v2,subvol=${SUBVOL},commit=120,nofail,x-systemd.device-timeout=15s"

FSTAB_MARK="# steam-machine: BTRFS RAID1 game library"
DEDUPE_UNITS=(steam-machine-dedupe.service steam-machine-dedupe.timer)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# need_root() now comes from lib/elevate.sh -- it elevates before dying.
scrub_unit() { echo "btrfs-scrub@$(systemd-escape -p "$MOUNT_POINT").timer"; }

array_present() { blkid -U "$FS_UUID" >/dev/null 2>&1; }
is_mounted()    { grep -q " $MOUNT_POINT btrfs " /proc/mounts; }

# Every device node belonging to the array, one per line.
#
# Read from btrfs sysfs rather than /dev/disk/by-uuid, which only ever points at
# whichever mirror member won the probe race -- and that is not necessarily the
# one /proc/mounts names. (It was not: by-uuid resolved to sdb while the mount
# recorded sda, so the old by-uuid lookup reported the array as NOT MOUNTED.)
# This works unprivileged, so --status stays useful without sudo. The directory
# exists only while the filesystem is mounted, which is all this is used for.
fs_devices() {
    local d
    for d in "/sys/fs/btrfs/$FS_UUID/devices/"*; do
        [[ -e "$d" ]] && echo "/dev/${d##*/}"
    done
}

# Every path the array is currently mounted at. More than one means the udisks
# rule is missing or was installed too late -- see ensure_udev.
fs_mount_points() {
    local devs dev
    mapfile -t devs < <(fs_devices)
    for dev in "${devs[@]}"; do
        awk -v d="$dev" '$1 == d && $3 == "btrfs" { print $2 }' /proc/mounts
    done | sort -u
}

# Where the array is mounted *right now*, which is not necessarily where fstab
# says it should be -- changing the mount point does not move a live mount.
current_mount_point() {
    local mps mp
    mapfile -t mps < <(fs_mount_points)
    # Prefer the configured path if the array is mounted in several places, so a
    # stray mount cannot mask the one that matters.
    for mp in "${mps[@]}"; do
        [[ "$mp" == "$MOUNT_POINT" ]] && { echo "$mp"; return 0; }
    done
    [[ ${#mps[@]} -gt 0 ]] && echo "${mps[0]}"
    return 0
}

# Mounts of this filesystem anywhere other than the configured mount point.
extra_mount_points() { fs_mount_points | grep -Fxv -- "$MOUNT_POINT" || true; }

# The mount point fstab currently records for this filesystem, if any.
fstab_mount_point() {
    awk -v uuid="UUID=$FS_UUID" '$1 == uuid { print $2; exit }' /etc/fstab
}

# Set by install_fstab when it moves an existing entry, so install_timers knows
# which stale path-instanced scrub timer to retire.
PREV_MOUNT_POINT=""

# --- SteamOS read-only rootfs -------------------------------------------------
# unlock_rootfs / relock_rootfs come from lib/rootfs.sh. They hold a repo-wide
# flock for the whole unlock..relock window: steamos-readonly is global state,
# and every subsystem's --boot unit starts in the same second, so without it one
# unit's relock lands in the middle of another's writes. See lib/rootfs.sh.

# --- mount point --------------------------------------------------------------
# The directory *underneath* the mount is deliberately root-owned and
# non-writable. With `nofail`, a mirror that fails to come up would otherwise
# leave a plain empty directory that Steam happily installs into -- silently
# filling the 2 TB boot NVMe while appearing to work. Locked down, Steam gets
# EACCES and says so.
prepare_mount_point() {
    if is_mounted; then
        log "already mounted at $MOUNT_POINT"
        return 0
    fi
    if [[ ! -d "$MOUNT_POINT" ]]; then
        log "creating mount point $MOUNT_POINT"
        mkdir -p "$MOUNT_POINT"
    fi
    chown root:root "$MOUNT_POINT"
    chmod 0555 "$MOUNT_POINT"
}

# --- fstab --------------------------------------------------------------------
install_fstab() {
    local existing; existing="$(fstab_mount_point)"

    if [[ "$existing" == "$MOUNT_POINT" ]]; then
        log "fstab entry already present"
        return 0
    fi

    log "backing up /etc/fstab -> /etc/fstab.bak-storage"
    cp -a /etc/fstab /etc/fstab.bak-storage

    if [[ -n "$existing" ]]; then
        # Moving the mount point. Only the fstab field changes -- nothing is
        # unmounted, so an array that is currently mounted (and being written
        # to) stays exactly where it is until the next boot.
        PREV_MOUNT_POINT="$existing"
        log "moving fstab mount point: $existing -> $MOUNT_POINT"
        # awk only rebuilds a record when a field is assigned, so every other
        # line in fstab passes through byte-for-byte.
        awk -v uuid="UUID=$FS_UUID" -v new="$MOUNT_POINT" -v OFS='\t' \
            '$1 == uuid { $2 = new } { print }' /etc/fstab > /etc/fstab.new
        mv /etc/fstab.new /etc/fstab
    else
        log "adding fstab entry for $MOUNT_POINT"
        {
            echo ""
            echo "$FSTAB_MARK (see hardware/storage/README.md)"
            printf 'UUID=%s %s btrfs %s 0 0\n' "$FS_UUID" "$MOUNT_POINT" "$MOUNT_OPTS"
        } >> /etc/fstab
    fi
    systemctl daemon-reload
}

# --- udisks suppression -------------------------------------------------------
# Cheap and idempotent, so it is safe on the boot fast path. Everything written
# here is under /etc, which is an overlayfs with its upper layer in /var --
# writable even with steamos-readonly enabled, so no rootfs unlock is needed.
render_udev() { sed "s/@FS_UUID@/$FS_UUID/g" "$UDEV_SRC"; }

ensure_udev() {
    local tmp changed=0
    tmp="$(mktemp)"
    render_udev > "$tmp"

    # cmp against the rendered text, not just an existence check: a rule left
    # over from a different UUID would otherwise look installed and match
    # nothing, which is exactly the kind of failure that is invisible until the
    # duplicate mounts reappear.
    if ! cmp -s "$tmp" "$UDEV_DEST"; then
        log "installing udev rule -> $UDEV_DEST"
        install -Dm644 "$tmp" "$UDEV_DEST"
        changed=1
    fi
    rm -f "$tmp"

    if ! cmp -s "$KEEP_SRC" "$KEEP_DEST"; then
        log "installing keep entry -> $KEEP_DEST"
        install -Dm644 "$KEEP_SRC" "$KEEP_DEST"
        changed=1
    fi

    if [[ $changed -eq 1 ]]; then
        udevadm control --reload-rules 2>/dev/null || warn "udevadm reload failed"
        # A reloaded rule only applies to devices that emit a uevent, and disks
        # do that at plug-in. Without the trigger the array stays visible in
        # Dolphin until the next reboot.
        udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
        udevadm settle --timeout=10 2>/dev/null || true
    fi
}

mount_array() {
    array_present || die "no filesystem with UUID $FS_UUID -- is the mirror connected?"

    # Already up somewhere else: the mount point was changed while the array was
    # in use. Mounting it a second time at the new path would leave the same
    # subvolume visible twice, which is a good way to confuse a game launcher
    # mid-install. Leave it alone; fstab already has the new path for next boot.
    local now; now="$(current_mount_point)"
    if [[ -n "$now" && "$now" != "$MOUNT_POINT" ]]; then
        warn "array is mounted at $now, but is configured for $MOUNT_POINT"
        warn "leaving the live mount untouched -- it moves on the next reboot"
        warn "to move it now instead: umount $now && mount $MOUNT_POINT"
        return 0
    fi

    if is_mounted; then
        log "already mounted"
    else
        log "mounting $MOUNT_POINT"
        mount "$MOUNT_POINT" || die "mount failed -- check: journalctl -b -u $(systemd-escape -p --suffix=mount "$MOUNT_POINT")"
    fi
    # The subvolume root itself must be writable by deck, unlike the directory
    # it is mounted over.
    chown deck:deck "$MOUNT_POINT"
    chmod 0755 "$MOUNT_POINT"
}

# --- maintenance timers -------------------------------------------------------
install_timers() {
    local want_dedupe=$1 unit

    # A RAID1 that is never scrubbed is a RAID1 that silently rots: btrfs only
    # notices a bad copy when something reads it, and game files sit untouched
    # for months. Scrub verifies every checksum and repairs from the good
    # mirror. This is the single most valuable thing on this list.
    # btrfs-scrub@ is instanced by escaped mount path, so a moved mount point
    # leaves the old instance enabled and pointed at a directory that will be
    # empty after the reboot -- it would fail every month, quietly.
    if [[ -n "$PREV_MOUNT_POINT" ]]; then
        local old="btrfs-scrub@$(systemd-escape -p "$PREV_MOUNT_POINT").timer"
        log "retiring stale scrub timer: $old"
        systemctl disable --now "$old" >/dev/null 2>&1 || warn "could not disable $old"
    fi

    log "enabling monthly scrub: $(scrub_unit)"
    # --now would start a scrub against a path that is not mounted yet when the
    # mount point has just been moved; enabling is enough, the timer fires later.
    systemctl enable "$(scrub_unit)" >/dev/null 2>&1 \
        || warn "could not enable $(scrub_unit)"

    # Belt and braces alongside discard=async: async discard can fall behind
    # under sustained deletes, and a weekly batch trim costs nothing.
    log "enabling fstrim.timer"
    systemctl enable --now fstrim.timer >/dev/null 2>&1 || warn "could not enable fstrim.timer"

    for unit in "${DEDUPE_UNITS[@]}"; do
        install -Dm644 "$REPO_DIR/systemd/$unit" "/etc/systemd/system/$unit"
    done

    # The boot-time self-heal. /etc/systemd/system/*.service is allowlisted, so
    # this unit survives an OS update and can put back the three things that do
    # not: the fstab entry, the udev rule, and the dedupe timer (*.timer is not
    # on the keep list even though *.service is).
    install -Dm644 "$REPO_DIR/systemd/$BOOT_UNIT" "/etc/systemd/system/$BOOT_UNIT"
    systemctl daemon-reload
    log "enabling $BOOT_UNIT"
    systemctl enable "$BOOT_UNIT" >/dev/null 2>&1 || warn "could not enable $BOOT_UNIT"

    if [[ $want_dedupe -eq 1 ]]; then
        log "enabling monthly dedupe timer"
        systemctl enable --now steam-machine-dedupe.timer >/dev/null 2>&1 \
            || warn "could not enable steam-machine-dedupe.timer"
    else
        log "dedupe timer installed but left disabled (--no-dedupe)"
    fi
}

# --- status -------------------------------------------------------------------
do_status() {
    local now fstab_mp
    now="$(current_mount_point)"
    fstab_mp="$(fstab_mount_point)"

    echo "array UUID:      $FS_UUID"
    echo -n "array present:   "; array_present && echo "yes" || echo "NO"
    echo "configured at:   $MOUNT_POINT"
    echo "fstab says:      ${fstab_mp:-MISSING}"
    echo "mounted at:      ${now:-NOT MOUNTED}"
    if [[ -n "$now" && -n "$fstab_mp" && "$now" != "$fstab_mp" ]]; then
        warn "pending move: live mount is $now, fstab says $fstab_mp -- applies at next boot"
    fi
    echo -n "mount options:   "
    if [[ -n "$now" ]]; then
        awk -v m="$now" '$2 == m && $3 == "btrfs" { print $4; exit }' /proc/mounts
    else
        echo "-"
    fi
    echo -n "mount point:     "
    if is_mounted; then
        stat -c '%U:%G %a (mounted)' "$MOUNT_POINT"
    else
        stat -c '%U:%G %a (bare dir -- should be root:root 555)' "$MOUNT_POINT" 2>/dev/null || echo "does not exist"
    fi
    echo -n "udisks rule:     "
    if [[ -f "$UDEV_DEST" ]] && cmp -s <(render_udev) "$UDEV_DEST"; then
        echo "installed"
    elif [[ -f "$UDEV_DEST" ]]; then
        echo "STALE -- does not match UUID $FS_UUID, rerun install.sh"
    else
        echo "MISSING -- array can be mounted a second time from Dolphin"
    fi
    echo -n "keep entry:      "
    [[ -f "$KEEP_DEST" ]] && echo "installed" || echo "MISSING (udev rule lost on next OS update)"
    echo -n "extra mounts:    "
    # What the udev rule exists to prevent: the same filesystem reachable by a
    # second path, typically /run/media/deck/SATA from a click in Dolphin.
    local extra; extra="$(extra_mount_points)"
    if [[ -n "$extra" ]]; then
        echo "$(wc -l <<<"$extra") -- unmount these, the array should be mounted once"
        sed 's/^/                 /' <<<"$extra"
    else
        echo "none"
    fi
    echo "timers:"
    printf '  %-34s %s\n' "$(scrub_unit)" "$(systemctl is-enabled "$(scrub_unit)" 2>&1)"
    printf '  %-34s %s\n' "fstrim.timer" "$(systemctl is-enabled fstrim.timer 2>&1)"
    printf '  %-34s %s\n' "steam-machine-dedupe.timer" "$(systemctl is-enabled steam-machine-dedupe.timer 2>&1)"
    printf '  %-34s %s\n' "$BOOT_UNIT" "$(systemctl is-enabled "$BOOT_UNIT" 2>&1)"
    echo -n "steam library:   "
    if grep -q "$MOUNT_POINT" /home/deck/.steam/steam/steamapps/libraryfolders.vdf 2>/dev/null; then
        echo "registered"
    else
        echo "NOT registered -- run bin/steam-add-library.sh with Steam closed"
    fi
}

# --- top level ----------------------------------------------------------------
do_install() {
    local want_dedupe=$1
    need_root
    trap relock_rootfs EXIT
    unlock_rootfs

    prepare_mount_point
    install_fstab
    ensure_udev
    mount_array
    install_timers "$want_dedupe"

    log "done"
    echo
    do_status
}

# Boot-time self-heal, run by steam-machine-storage.service.
#
# Neither /etc/fstab nor /etc/udev/rules.d is on the SteamOS keep list, so an
# A/B update silently takes the mount and the udisks rule with it. Both live in
# /etc -- an overlay whose upper layer is in /var -- so this needs no rootfs
# unlock and no pacman. Everything it calls is a no-op when nothing is missing.
#
# It deliberately does not mount anything: a restored fstab entry applies at the
# next boot. Remounting underneath a running session is the worse failure on a
# machine whose only display is a TV.
# Second line of defence for the *.timer gap described in the keep conf: the
# keep entry should carry the timer across an update, and this puts it back if
# it does not. Deliberately does not re-enable -- the wants symlink IS
# allowlisted and survives, and re-enabling would quietly undo --no-dedupe.
ensure_units() {
    local unit restored=0
    for unit in "${DEDUPE_UNITS[@]}"; do
        cmp -s "$REPO_DIR/systemd/$unit" "/etc/systemd/system/$unit" && continue
        install -Dm644 "$REPO_DIR/systemd/$unit" "/etc/systemd/system/$unit"
        warn "restored /etc/systemd/system/$unit (was missing or modified)"
        restored=1
    done
    if ! cmp -s "$KEEP_SRC" "$KEEP_DEST"; then
        install -Dm644 "$KEEP_SRC" "$KEEP_DEST"
        warn "restored $KEEP_DEST (was missing or modified)"
    fi
    [[ $restored -eq 1 ]] && { systemctl daemon-reload || true; }
    return 0
}

do_boot() {
    need_root
    ensure_udev
    install_fstab
    ensure_units
}

do_uninstall() {
    need_root
    trap relock_rootfs EXIT
    unlock_rootfs
    local unit
    systemctl disable --now steam-machine-dedupe.timer >/dev/null 2>&1 || true
    systemctl disable --now "$(scrub_unit)" >/dev/null 2>&1 || true
    systemctl disable "$BOOT_UNIT" >/dev/null 2>&1 || true
    for unit in "${DEDUPE_UNITS[@]}"; do rm -f "/etc/systemd/system/$unit"; done
    rm -f "/etc/systemd/system/$BOOT_UNIT"
    systemctl daemon-reload
    # Removing the rule hands the array back to udisks, which is the right
    # end state for an uninstall: without an fstab entry, clicking it in
    # Dolphin is the only way left to mount it.
    rm -f "$UDEV_DEST" "$KEEP_DEST"
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
    is_mounted && umount "$MOUNT_POINT"
    if grep -q "$FS_UUID" /etc/fstab; then
        log "removing fstab entry (backup at /etc/fstab.bak-storage)"
        cp -a /etc/fstab /etc/fstab.bak-storage
        grep -v -e "$FS_UUID" -e "$FSTAB_MARK" /etc/fstab > /etc/fstab.new
        mv /etc/fstab.new /etc/fstab
        systemctl daemon-reload
    fi
    log "uninstalled -- the filesystem and everything on it is untouched"
}

case "${1:-}" in
    ""|--install) do_install 1 ;;
    --no-dedupe)  do_install 0 ;;
    --status)     do_status ;;
    --boot)       do_boot ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
