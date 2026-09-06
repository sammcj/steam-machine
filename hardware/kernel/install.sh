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
#   ./install.sh --confirm  cache the installed kernel, but ONLY if this boot
#                           is running it and has reached a graphical session;
#                           run from steam-machine-kernel-confirm.timer
#   ./install.sh --install-build [modules-dir]
#                           install the kernel sitting in the BUILD TREE, so
#                           there is something to boot and then --cache
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
_l=$(_lib) && source "$_l" && source "${_l%/*}/rootfs.sh"


REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${FRL_KERNEL_CACHE:-/home/deck/.cache/frl-kernel}"
BUILD_TREE="${FRL_BUILD_TREE:-/home/deck/kernel-frl/build72}"

KVER_FILE="$CACHE_DIR/kver"
# Serialises the paths that mutate the installed kernel against the one that
# packs it. See kernel_lock().
KERNEL_LOCK="$CACHE_DIR/.install.lock"
# Which BUILD the cache holds, as opposed to which release string. See
# build_id_of_image() for why the release alone is not enough.
BUILDID_FILE="$CACHE_DIR/buildid"
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
# Caches the kernel only after a boot that reached the GUI on it. The .timer is
# the enabled half; the .service has no [Install] and is started by nothing
# else. The timer needs an atomic-update entry that the other units do not --
# see atomic-update.conf.d/steam-machine-kernel.conf for why.
CONFIRM_UNIT="steam-machine-kernel-confirm.service"
CONFIRM_TIMER="steam-machine-kernel-confirm.timer"
CONFIRM_DEST="/etc/systemd/system/$CONFIRM_UNIT"
CONFIRM_TIMER_DEST="/etc/systemd/system/$CONFIRM_TIMER"

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

# The version a kernel IMAGE actually is, read out of the bzImage header rather
# than taken on trust from a path or a preset. This is the only way to catch the
# drift that broke the 2026-08-28 restore: two different builds can carry the
# same release string, and a stale cache looks identical to a fresh one from
# every other angle.
kver_of_image() {
    local out
    out="$(file -b "$1" 2>/dev/null)" || return 1
    [[ $out == *"bzImage, version "* ]] || return 1
    out=${out#*bzImage, version }
    printf '%s\n' "${out%% *}"
}

# Identity of a kernel BUILD rather than of a kernel release.
#
# CONFIG_LOCALVERSION is fixed at "-frlprobe", so every build out of the same
# tree reports the same release string and kver_of_image() cannot tell a rebuilt
# kernel from the installed one. That is exactly the drift that cost the machine
# its kernel on 2026-08-28. The link counter (`#N`) in the banner increments on
# every relink, so release + #N does distinguish them.
#
# It is not a hash -- two builds from two different trees could in principle
# collide on both -- but it is the only identity the RUNNING kernel exposes,
# and matching the running kernel against an installed image is the whole point.
# /proc/version and file(1) print the same two fields in the same order:
#
#   /proc/version  Linux version 7.2.0-frlprobe (root@...) (gcc ...) #10 SMP ...
#   file(1)        ... bzImage, version 7.2.0-frlprobe (root@...) #10 SMP ...
#
# Note the compiler string, which only /proc/version carries: that is why this
# picks two fields out rather than comparing the banners whole.
_build_id_from_banner() {
    local v="$1" rel num
    rel="${v%% *}"
    [[ $v == *"#"* ]] || return 1
    num="${v#*\#}"
    num="${num%% *}"
    [[ -n $rel && -n $num ]] || return 1
    printf '%s #%s\n' "$rel" "$num"
}

build_id_of_image() {
    local out
    out="$(file -b "$1" 2>/dev/null)" || return 1
    [[ $out == *"bzImage, version "* ]] || return 1
    _build_id_from_banner "${out#*bzImage, version }"
}

build_id_running() {
    local v
    v="$(< /proc/version)" || return 1
    [[ $v == "Linux version "* ]] || return 1
    _build_id_from_banner "${v#Linux version }"
}

cached_build_id() { [[ -f $BUILDID_FILE ]] && cat "$BUILDID_FILE"; }

# --- serialising the installed kernel against the thing that packs it ---------

# Everything that MUTATES the installed kernel takes this lock, and so does
# build_cache. Until --confirm existed the two could not overlap, because both
# were things a human ran one after the other; a timer changed that.
#
# The window is real and it is wide. do_install_build() replaces the module tree
# first and copies the vmlinuz LAST, so for the ~30 s of a 180 MB `cp -a` plus
# depmod the installed image is the OLD build sitting next to the NEW modules.
# --confirm compares /proc/version against the image alone, so mid-window it
# sees running == installed, passes every other gate, and packs exactly the
# mismatched pair that cost the machine its kernel on 2026-08-28 -- into the
# only copy that survives an A/B update. deploy_kernel() has the same shape.
#
# The lock lives in the cache directory rather than /run because both ends of it
# already require that directory to exist, and because it must work identically
# from a systemd unit and from an interactive shell.
# ALWAYS call this AFTER need_root, never before. need_root re-runs the whole
# script under sudo (lib/elevate.sh), and the child inherits the parent's open
# file descriptors: a lock taken first would be held by the unprivileged parent
# while the root child blocked on it forever. That is the class of hang this
# repo's CLAUDE.md exists to prevent.
# Acquire and release, NOT a `with_lock <body>` wrapper.
#
# The wrapper spelling is the obvious one and it is wrong here. Running the body
# as `"$@" || rc=$?` puts it on the left of `||`, which switches `set -e` OFF for
# that function and everything it calls -- so a half-finished `cp -a` of the
# module tree would no longer abort do_install_build, and it would go on to
# install the new vmlinuz beside the old modules and rewrite custom.cfg. That is
# precisely the mismatched pair this whole subsystem exists to keep out of the
# cache, manufactured by the thing meant to protect it. It also silently kills
# the `set -e` guards those bodies were written around -- custom_cfg_installed()
# relies on one (see its comment) to avoid `grep -q ""` matching anything.
#
# Called as plain statements instead, errexit applies normally. A `die` in the
# body exits the process, and the kernel releases the flock on exit, so nothing
# leaks.
KERNEL_LOCK_FD=

# ALWAYS call this AFTER need_root, never before. need_root re-runs the whole
# script under sudo (lib/elevate.sh), and the child inherits the parent's open
# file descriptors: a lock taken first would be held by the unprivileged parent
# while the root child blocked on it forever. That is the class of hang this
# repo's CLAUDE.md exists to prevent.
kernel_lock() {
    local mode="${1:-wait}"   # 'wait' for mutators, 'try' for the timer
    mkdir -p "$CACHE_DIR"
    exec {KERNEL_LOCK_FD}<>"$KERNEL_LOCK"
    if [[ $mode == try ]]; then
        # Non-blocking on purpose: an install in progress means this boot has
        # not finished becoming what it will be, so there is nothing honest to
        # cache yet. The timer comes back in 30 minutes. Returns 1, which the
        # caller turns into a clean exit 0 -- this is not a failure.
        if flock -n "$KERNEL_LOCK_FD"; then return 0; fi
        exec {KERNEL_LOCK_FD}>&-
        KERNEL_LOCK_FD=
        log "another install.sh holds the kernel lock -- will retry"
        return 1
    fi
    # Bounded, not indefinite. Nothing legitimately holds this for more than
    # about a minute (a 180 MB pack, or an install), and the boot unit that
    # takes it has TimeoutStartSec=600 -- so failing at 300 s leaves room to
    # report the failure properly instead of being killed mid-restore.
    flock -w 300 "$KERNEL_LOCK_FD" \
        || die "timed out waiting for the kernel lock at $KERNEL_LOCK -- another install.sh is stuck; check with: fuser -v $KERNEL_LOCK"
}

kernel_unlock() {
    [[ -n ${KERNEL_LOCK_FD:-} ]] || return 0
    exec {KERNEL_LOCK_FD}>&-
    KERNEL_LOCK_FD=
}

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
# unlock_rootfs / relock_rootfs come from lib/rootfs.sh. They hold a repo-wide
# flock for the whole unlock..relock window: steamos-readonly is global state,
# and every subsystem's --boot unit starts in the same second, so without it one
# unit's relock lands in the middle of another's writes. See lib/rootfs.sh.

# --- cache --------------------------------------------------------------------

# Packs the built kernel into a single tarball under /home. This is what makes
# reinstalling after an A/B update cheap: no rebuild, no container, no network.
# Packs the INSTALLED kernel and the INSTALLED modules -- the pair that has
# actually booted -- never the build tree's bzImage.
#
# It used to take the image from $BUILD_TREE/arch/x86/boot/bzImage while taking
# the modules from /usr/lib/modules, and on 2026-08-28 that cost the machine its
# kernel. The build tree had been rebuilt (the pstore config change) without the
# result ever being installed, so `--cache` packed an 8 Aug bzImage next to 6 Aug
# modules. CONFIG_LOCALVERSION makes every build report the same release string,
# so nothing downstream could tell: --status said the cache was current, the
# restore after the SteamOS update deployed the mismatched pair, and it hung at
# the splash with no journal.
#
# So the version now comes out of the image header, and the build tree is only
# consulted to warn that it has moved ahead of what is installed.
# Split in two because flock is per open-file-description: do_confirm already
# holds the lock when it calls this, and a nested kernel_lock would open the
# file a second time and block on itself. The public entry point takes the
# lock; the _locked body assumes it is held.
build_cache() {
    need_root --cache
    kernel_lock wait
    _build_cache_locked
    kernel_unlock
}

_build_cache_locked() {
    local img="$BOOT_SUBDIR/vmlinuz-linux-frlprobe"
    [[ -f $img ]] || die "no installed kernel at $img -- run a full install first"

    local kver
    kver="$(kver_of_image "$img")" || die "cannot read the kernel version out of $img"
    [[ -n $kver ]] || die "empty kernel version from $img"

    [[ -d "/usr/lib/modules/$kver" ]] \
        || die "modules for $kver are not installed; run a full install first"

    if [[ -f "$BUILD_TREE/arch/x86/boot/bzImage" ]] \
       && ! cmp -s "$BUILD_TREE/arch/x86/boot/bzImage" "$img"; then
        warn "the build tree holds $(kver_of_image "$BUILD_TREE/arch/x86/boot/bzImage" || echo '?') and it is NOT what is installed ($kver)"
        warn "caching the installed kernel. Install the build first if that is the one you want cached."
    fi

    log "packing $kver into the cache"
    mkdir -p "$CACHE_DIR"

    local stage
    stage="$(mktemp -d)"
    # A RETURN trap set inside a function STAYS INSTALLED after that function
    # returns, and fires again for the next function that returns -- by which
    # point bash has popped these locals, so `rm -rf "$stage"` hits `set -u` and
    # kills the script with "unbound variable". hardware/rgb/install.sh:89
    # records the same lesson.
    #
    # Latent while this body was called straight from the dispatch and nothing
    # returned after it. Live the moment it moved behind kernel_lock: the
    # pack SUCCEEDS, then the wrapper returns, the trap re-fires, and --cache
    # exits 1 having done its job perfectly -- marking the confirm unit failed
    # for a cache that is correct. Guarded expansion, and the trap disarms
    # itself as its own last act so it cannot fire a second time.
    trap '[[ -n ${stage:-} ]] && rm -rf "$stage"; trap - RETURN' RETURN

    mkdir -p "$stage/boot" "$stage/usr/lib/modules"
    cp "$img" "$stage/boot/vmlinuz-linux-frlprobe"
    cp -a "/usr/lib/modules/$kver" "$stage/usr/lib/modules/"
    # The build symlink points into the build tree; it is not part of the
    # runtime artefact and would be a dangling link after a restore.
    rm -f "$stage/usr/lib/modules/$kver/build"

    # -3, not -19: the modules are already individually zstd-compressed, so a
    # high level costs minutes and saves almost nothing.
    # The partial file is cleaned up on failure. `set -o pipefail` aborts the
    # whole script if either half of this pipe fails, and the RETURN trap above
    # does not fire on a `set -e` abort -- so without this an out-of-space run
    # leaves ~180 MB of .new sitting in the cache directory forever, on the
    # filesystem that just ran out of space.
    if ! { tar -C "$stage" -c boot usr | zstd -q -T0 -3 > "$CACHE_DIR/kernel.tar.zst.new"; }; then
        # Both the partial tarball and the staging tree, explicitly: die() exits
        # the script, so the RETURN trap above never fires on this path.
        rm -f "$CACHE_DIR/kernel.tar.zst.new"
        rm -rf "$stage"
        die "packing $kver failed (out of space on /home?) -- the existing cache is untouched"
    fi
    mv "$CACHE_DIR/kernel.tar.zst.new" "$CACHE_DIR/kernel.tar.zst"
    echo "$kver" > "$KVER_FILE"
    # Written after the tarball is in place, so an interrupted pack leaves the
    # build id pointing at the previous contents rather than claiming the new
    # one. --confirm compares against this to decide it has nothing to do; a
    # missing or stale value costs one redundant re-pack, never a wrong cache.
    build_id_of_image "$img" > "$BUILDID_FILE" || rm -f "$BUILDID_FILE"

    chown -R deck:deck "$CACHE_DIR"
    log "cached $(du -h "$CACHE_DIR/kernel.tar.zst" | cut -f1) at $CACHE_DIR"
}

# --- confirm ------------------------------------------------------------------

# Is somebody actually looking at a desktop or a game?
#
# Asked of logind rather than of a process list, because this machine has two
# entirely different graphical stacks -- gamescope in Game Mode, KWin in Desktop
# Mode -- and pgrep for both is a list that goes stale the first time Valve
# renames something. A seat0 session that logind calls active, of type wayland
# or x11, is true for both and needs no updating.
#
# Class=user excludes the `manager` session systemd opens for the user's own
# unit tree, which exists whether or not anything is on screen.
gui_is_up() {
    local s props
    while read -r s; do
        [[ -n $s ]] || continue
        props="$(loginctl show-session "$s" -p Class -p Type -p State -p Seat 2>/dev/null)" || continue
        [[ $props == *"Class=user"*   ]] || continue
        [[ $props == *"State=active"* ]] || continue
        [[ $props == *"Seat=seat0"*   ]] || continue
        [[ $props == *"Type=wayland"* || $props == *"Type=x11"* ]] || continue
        return 0
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')

    # Fallback, and the reason it exists: the logind test above is VERIFIED in
    # Desktop Mode (session type wayland, seat0, active) and only assumed in
    # Game Mode, which is how this machine actually spends its life. If
    # gamescope's session registers with a different Type or no seat, the test
    # above silently never passes and the cache never updates -- a failure with
    # no symptom until the next OS update, which is the whole thing this
    # mechanism exists to prevent.
    #
    # So: one named process, checked only after the general test has failed. It
    # is a compositor holding the display, which is the question being asked.
    # If this is what ends up firing, fix the test above rather than adding a
    # second name here.
    pgrep -x gamescope >/dev/null 2>&1
}

# The out-of-tree modules are the ones nobody notices are missing. it87 is every
# fan and temperature sensor on this board; btusb_mt7902 is Bluetooth, so losing
# it means no controllers. Both have to be rebuilt by hand against each new
# kernel (README step 4) and both fail silently when they were not -- the kernel
# boots, the GUI comes up, and the machine simply has no sensors.
#
# So they gate the cache instead of warning about it: a kernel cached without
# them is a kernel that redeploys itself, without them, at every future SteamOS
# update. `--cache` remains the override -- it caches whatever is installed, no
# questions asked -- for the case where one of them is genuinely not wanted.
# Gates on whether the modules are BUILT, and only warns about whether they are
# LOADED. The two look alike and are not:
#
#   built   -- decides what goes into the tarball, which is the only thing this
#              function is here to protect. A kernel cached without them
#              redeploys a machine with no sensors and no Bluetooth at every
#              future OS update.
#   loaded  -- a runtime condition with causes that have nothing to do with the
#              cache: it87 needs the sensors subsystem's modprobe.d (not on
#              Valve's keep list), btusb_mt7902 needs the radio present and not
#              rfkill-blocked. Blocking on it would wedge caching permanently
#              and invisibly -- exit 0 every 30 minutes, no failed unit, and the
#              reason only in the journal.
#
# The warning still goes out, because a module that is built and not loaded is
# usually something else being broken.
confirm_oot_modules() {
    local kver="$1" m unbuilt=()
    for m in it87 btusb_mt7902; do
        if ! compgen -G "/usr/lib/modules/$kver/updates/$m.ko*" >/dev/null; then
            unbuilt+=("$m")
        elif ! grep -q "^$m " /proc/modules; then
            warn "$m is built against $kver but not loaded -- caching anyway, but something is wrong"
        fi
    done
    [[ ${#unbuilt[@]} -eq 0 ]] && return 0
    for m in "${unbuilt[@]}"; do warn "$m: not built against $kver"; done
    return 1
}

# Cache the installed kernel, but only on the evidence of a boot that worked.
#
# This exists because the documented flow -- install, reboot, check, then
# --cache -- has a step that depends on a human remembering it days later, and
# the cost of forgetting is silent: the machine keeps running the new kernel
# until the next SteamOS update swaps the rootfs, at which point --boot restores
# whatever the cache still holds and the new kernel is gone. That is how the
# machine arrived on 7.2.0 on 2026-09-06 having been rebased to 7.2.2.
#
# Every exit short of caching is exit 0. The timer re-fires, and a boot that has
# not earned a cache entry is a normal state, not a failure -- a failed unit
# here would be indistinguishable from the ones that mean something.
do_confirm() {
    need_root --confirm
    # `try`, not `wait`: if an install is running, this boot has not finished
    # becoming what it will be and there is nothing honest to cache yet. Taking
    # the lock around the CHECKS as well as the pack is the point -- checking
    # outside it and packing inside would re-open the same window.
    #
    # The `|| return 0` is on kernel_lock alone, never on the body: putting the
    # body on the left of `||` would disable `set -e` inside it.
    kernel_lock try || return 0
    _confirm_locked
    kernel_unlock
}

_confirm_locked() {
    local img="$BOOT_SUBDIR/vmlinuz-linux-frlprobe"
    [[ -f $img ]] || { log "no FRL kernel installed -- nothing to confirm"; return 0; }

    local installed running
    installed="$(build_id_of_image "$img")" \
        || { warn "cannot read a build id out of $img -- not caching"; return 0; }
    running="$(build_id_running)" \
        || { warn "cannot read a build id out of /proc/version -- not caching"; return 0; }

    # The load-bearing check. Running the stock Valve kernel means either this
    # boot never tried the FRL entry or GRUB's fallback caught a broken one --
    # and in the second case the installed image is precisely the thing that
    # must NOT be cached.
    if [[ $running != "$installed" ]]; then
        log "running '$running', installed FRL kernel is '$installed' -- not this boot's kernel, nothing to confirm"
        return 0
    fi

    if [[ -f "$CACHE_DIR/kernel.tar.zst" && "$(cached_build_id || true)" == "$installed" ]]; then
        log "cache already holds '$installed' -- nothing to do"
        return 0
    fi

    if ! gui_is_up; then
        log "no active graphical session yet -- leaving the cache alone, will retry"
        return 0
    fi

    if ! confirm_oot_modules "$(uname -r)"; then
        warn "out-of-tree modules missing -- refusing to cache '$installed'"
        warn "rebuild them (README step 4), then: sudo $0 --cache"
        return 0
    fi

    log "'$installed' booted to a graphical session -- caching it"
    # The lock is already held, so the _locked body directly. A genuine pack
    # failure (no space on /home) is the ONE case that fails this unit rather
    # than exiting 0: it leaves the cache holding a kernel that is no longer the
    # one running, which is exactly the drift worth a red `systemctl status`.
    _build_cache_locked
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
    # A failed extraction is cleaned up rather than left half-done. The 2026-08-28
    # case was a sibling boot unit re-enabling steamos-readonly mid-tar, which
    # left a vmlinuz with no modules and no initramfs -- enough for GRUB to try
    # the entry and fail. /boot/frl goes back to empty so the next attempt starts
    # clean, and so custom.cfg's -s guard sees nothing to boot.
    if ! tar -C / --zstd -xf "$CACHE_DIR/kernel.tar.zst" \
        --transform 's|^boot/|boot/frl/|' boot usr; then
        rm -rf "$BOOT_SUBDIR" "/usr/lib/modules/$kver"
        die "extracting $CACHE_DIR/kernel.tar.zst failed (read-only rootfs? full /boot?) -- nothing installed"
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
    install -Dm644 "$REPO_DIR/systemd/$CONFIRM_UNIT" "$CONFIRM_DEST"
    install -Dm644 "$REPO_DIR/systemd/$CONFIRM_TIMER" "$CONFIRM_TIMER_DEST"
    systemctl daemon-reload
    systemctl enable steam-machine-kernel.service >/dev/null 2>&1 \
        || warn "could not enable steam-machine-kernel.service"
    systemctl enable "$VT_UNIT" >/dev/null 2>&1 \
        || warn "could not enable $VT_UNIT -- power-off may hang"
    # The timer, not the service: the service has no [Install] on purpose.
    # Failing to enable it costs the automatic cache, nothing else, so it warns
    # rather than dying -- the manual `--cache` still works.
    systemctl enable "$CONFIRM_TIMER" >/dev/null 2>&1 \
        || warn "could not enable $CONFIRM_TIMER -- caching stays manual (--cache)"
}

do_install() {
    need_root --install
    kernel_lock wait
    _do_install_locked
    kernel_unlock
}

_do_install_locked() {
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
    need_root --boot
    # The /etc self-heal runs BEFORE the lock is even acquired.
    #
    # It writes only /etc -- the mt7921e blacklist, the shutdown VT unit, the
    # confirm pair, the keep list -- touches no kernel state, and so needs no
    # serialisation. Putting it ahead of kernel_lock keeps the promise its own
    # comment makes ("ahead of every early return"): a lock that cannot be
    # opened, or that times out at 300 s, must not be able to leave the mt7921e
    # blacklist unrestored, because that is a power-off that never completes.
    _boot_etc_selfheal
    kernel_lock wait
    _boot_restore_kernel
    kernel_unlock
}

_boot_etc_selfheal() {
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

    # The confirm pair, restored ahead of the cached-kernel fast path for the
    # same reason as the two above: it has to come back even on a boot where
    # everything else was already intact. The .timer is the one that genuinely
    # needs it -- see atomic-update.conf.d/steam-machine-kernel.conf.
    local u dest reloaded=0
    for u in "$CONFIRM_UNIT" "$CONFIRM_TIMER"; do
        dest="/etc/systemd/system/$u"
        if [[ -f "$REPO_DIR/systemd/$u" ]] && ! cmp -s "$REPO_DIR/systemd/$u" "$dest"; then
            install -Dm644 "$REPO_DIR/systemd/$u" "$dest" \
                && { log "restored $dest"; reloaded=1; } \
                || warn "could not restore $dest -- the kernel cache will not update itself"
        fi
    done
    # The atomic-update entry, by CONTENT and not merely by existence.
    #
    # The fast path below only tests `-f $KEEP_DEST`, so editing the keep list
    # in the repo -- adding a newly-installed file to it, say -- would never
    # reach /etc on a machine where the old copy is still sitting there. The
    # symptom is the worst kind this subsystem has: everything looks installed,
    # and the newly-listed file disappears at the next OS update anyway.
    if [[ -f "$REPO_DIR/atomic-update.conf.d/steam-machine-kernel.conf" ]] \
       && ! cmp -s "$REPO_DIR/atomic-update.conf.d/steam-machine-kernel.conf" "$KEEP_DEST"; then
        install -Dm644 "$REPO_DIR/atomic-update.conf.d/steam-machine-kernel.conf" "$KEEP_DEST" \
            && log "restored $KEEP_DEST (keep list)" \
            || warn "could not restore $KEEP_DEST -- units may not survive an OS update"
    fi

    if [[ $reloaded -eq 1 ]]; then systemctl daemon-reload; fi
    systemctl is-enabled --quiet "$CONFIRM_TIMER" 2>/dev/null \
        || systemctl enable "$CONFIRM_TIMER" >/dev/null 2>&1 \
        || warn "could not enable $CONFIRM_TIMER -- caching stays manual (--cache)"

    # Enabling only writes the timers.target.wants symlink, and timers.target was
    # reached long before this unit runs (it is WantedBy=multi-user.target). So a
    # timer restored here stays INACTIVE for the rest of this boot -- meaning the
    # exact scenario this self-heal exists for, an A/B update having deleted it,
    # would still produce no caching until the next reboot. Start it too.
    #
    # --no-block is mandatory, not tidiness: this runs inside
    # steam-machine-kernel.service's own ExecStart, and systemd will not dispatch
    # the new job while the calling unit's job is still running. A blocking start
    # here is the deadlock that made the machine unbootable on 2026-09-06 via
    # hardware/usb/. Keyed on INVOCATION_ID so an interactive `--boot` still gets
    # a real exit status.
    local nb=()
    [[ -n ${INVOCATION_ID:-} ]] && nb=(--no-block)
    systemctl is-active --quiet "$CONFIRM_TIMER" 2>/dev/null \
        || systemctl start "${nb[@]}" "$CONFIRM_TIMER" >/dev/null 2>&1 \
        || warn "could not start $CONFIRM_TIMER -- it will come up at the next boot"
}

# The half that touches the kernel, and the only half that needs the lock.
_boot_restore_kernel() {
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
    echo "confirm timer      : $(systemctl is-enabled "$CONFIRM_TIMER" 2>/dev/null || echo 'NO -- caching is manual')"
    # The build the cache holds, next to the build that is running. These are
    # the two values --confirm compares, so printing them makes its decision
    # legible rather than something you have to read the journal to explain --
    # and a release string alone cannot show a same-release rebuild drifting.
    # Three builds, not two, and they answer three different questions:
    #   installed -- what the FRL boot entry will load at the next reboot
    #   running   -- what booted this time (the stock kernel, usually, after an
    #                OS update or a deliberate menu choice)
    #   cached    -- what a SteamOS A/B update will restore, replacing installed
    # Printing only two of them hides the state that matters most right after an
    # --install-build: a new kernel installed but not yet cached.
    echo "installed build    : $(build_id_of_image "$BOOT_SUBDIR/vmlinuz-linux-frlprobe" 2>/dev/null || echo '<none>')"
    echo "running build      : $(build_id_running || echo '?')"
    echo "cached build       : $(cached_build_id || echo '<unknown -- predates build ids; --confirm refreshes it after a boot on the FRL kernel>')"
    # Has anything been installed into the module tree since the cache was
    # built? If so it is NOT protected: a SteamOS update restores the tarball
    # and silently drops it. This caught the hand-installed hid-steam backport.
    if [[ -n ${kver:-} && -d "/usr/lib/modules/$kver" && -f "$CACHE_DIR/kernel.tar.zst" ]]; then
        # depmod rewrites modules.dep/.alias/.symbols and friends on every
        # restore, so they are ALWAYS newer than the tarball and made this check
        # cry wolf immediately after a self-heal. They are generated, not
        # content: dropping them leaves the case worth warning about, a .ko
        # installed by hand under kernel/ or updates/. `|| true` because
        # `set -o pipefail` turns grep's "no lines" into a failed assignment.
        newest="$(find "/usr/lib/modules/$kver" -newer "$CACHE_DIR/kernel.tar.zst" -type f -printf '%P\n' 2>/dev/null \
            | grep -v '^modules\.' | head -3)" || true
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

# Installs the kernel that is sitting in the BUILD TREE, rather than the one in
# the cache. This is the first half of the rebuild flow, and it exists because
# --cache now packs what is installed: a freshly built kernel has to reach
# /boot/frl and /usr/lib/modules before there is anything honest to cache.
#
#   ./install.sh --install-build [modules-dir]     modules-dir defaults to
#                                                  $BUILD_TREE/../stage<N>/lib/modules
#
# Then boot it, confirm it works, and only then run --cache. That order is the
# whole lesson of 2026-08-28: a cache entry that has never booted is not a
# backup, it is an untested kernel scheduled to deploy itself unattended.
#
# Out-of-tree modules are NOT built here -- see ../sensors/ and ../bluetooth/ --
# but their absence is called out, because losing them silently is how a probe
# boot ends up with no fan readings and no Bluetooth.
do_install_build() {
    need_root --install-build "$@"
    kernel_lock wait
    _do_install_build_locked "$@"
    kernel_unlock
}

_do_install_build_locked() {
    local bz="$BUILD_TREE/arch/x86/boot/bzImage"
    [[ -f $bz ]] || die "no bzImage at $bz (set FRL_BUILD_TREE)"

    local kver
    kver="$(kver_of_image "$bz")" || die "cannot read the kernel version out of $bz"
    log "build tree holds $kver"

    # Where modules_install put the tree. An explicit argument wins; otherwise
    # take the newest stage*/lib/modules/$kver next to the build tree.
    local mods="${1:-}"
    if [[ -z $mods ]]; then
        local d
        for d in "$(dirname "$BUILD_TREE")"/stage*/lib/modules/"$kver"; do
            [[ -d $d ]] && mods="$d"
        done
    fi
    [[ -n $mods && -d $mods ]]         || die "no staged modules for $kver -- run 'make modules_install INSTALL_MOD_PATH=...' first, or pass the path"
    log "staged modules at $mods"

    unlock_rootfs
    trap relock_rootfs EXIT

    log "installing the $kver module tree"
    rm -rf "/usr/lib/modules/$kver"
    cp -a "$mods" "/usr/lib/modules/$kver"
    chown -R root:root "/usr/lib/modules/$kver"
    # Points into the build tree; dangling after a restore, and not part of the
    # runtime artefact.
    rm -f "/usr/lib/modules/$kver/build"

    if [[ ! -d "/usr/lib/modules/$kver/updates" ]]; then
        warn "no updates/ in the module tree -- it87 and btusb_mt7902 are NOT installed"
        warn "build them against $BUILD_TREE and install them before rebooting, or this kernel"
        warn "boots with no fan or temperature readings and no Bluetooth"
    fi

    depmod "$kver"

    log "installing the kernel image"
    mkdir -p "$BOOT_SUBDIR"
    install -Dm644 "$bz" "$BOOT_SUBDIR/vmlinuz-linux-frlprobe"

    install_preset_file
    regen_initramfs "$kver"
    install_grub_entry
    install_service

    log "installed $kver from the build tree"
    log "NEXT: reboot into it. steam-machine-kernel-confirm.timer caches it 10 minutes"
    log "      later, if this boot is running it and reached a graphical session."
    log "      To do it by hand instead: sudo ./install.sh --cache"
    warn "the cache still holds $(cached_kver || echo '<nothing>') until then -- an OS update before that point restores the old kernel"
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
    systemctl disable --now "$CONFIRM_TIMER" >/dev/null 2>&1 || true
    rm -f "$SERVICE_DEST" "$KEEP_DEST" "$PRESET_DEST" "$MODPROBE_DEST" "$VT_DEST" \
          "$CONFIRM_DEST" "$CONFIRM_TIMER_DEST"
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
    --confirm)    do_confirm ;;
    --install-build) shift; do_install_build "${1:-}" ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    -h|--help)    sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ;;
    *)            die "unknown option: $1 (try --help)" ;;
esac
