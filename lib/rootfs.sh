# Shared read-only-rootfs handling for this repo's scripts. Source it, do not
# execute it. Sourced alongside lib/elevate.sh:
#
#   _l=$(_lib) && source "$_l" && source "${_l%/*}/rootfs.sh"
#
# Provides:
#   unlock_rootfs   take the repo-wide rootfs lock, then `steamos-readonly disable`
#   relock_rootfs   `steamos-readonly enable` if WE disabled it, then release the lock
#
# Drop-in for the near-identical pair every subsystem's install.sh used to
# define, including the RO_WAS_ENABLED convention, so callers only change their
# source line.
#
# ---------------------------------------------------------------------------
# WHY THERE IS A LOCK
#
# Each subsystem's `install.sh --boot` is its own oneshot unit wanted by
# multi-user.target, so systemd starts all thirteen of them in the same second.
# Several of them unlock the rootfs, write to /usr, and relock on exit --
# and steamos-readonly is a single piece of global state with no ownership.
#
# What that cost, on the 2026-08-28 SteamOS update:
#
#   17:51:28  kernel  `steamos-readonly status` -> disabled, because a sibling
#                     unit had already unlocked. So it did not unlock, and had
#                     nothing to relock either. It began extracting the cached
#                     kernel into /boot and /usr.
#   17:51:28  sibling finished its own work and ran `steamos-readonly enable`.
#   17:51:28  kernel  tar: usr/lib/modules/...: Cannot mkdir: Read-only file
#                     system -- mid-extraction, exit 2.
#
# The result was an FRL install with a vmlinuz, no modules, no initramfs and a
# custom.cfg still naming the previous slot's rootfs UUID: the machine booted
# to a GRUB error that waits for a keypress on a TV with no keyboard near it.
# The window is small but it is hit on exactly the boot that matters -- the
# first one after an update, when every unit has real work to do at once.
#
# So: one exclusive flock, taken BEFORE the status check and released AFTER the
# relock. Whoever holds it owns the read-only state for the whole of its
# critical section; everyone else waits. The lock lives in /run, so it is gone
# after a reboot and cannot deadlock a later boot.
# ---------------------------------------------------------------------------

# Set by unlock_rootfs, read by relock_rootfs. Callers still initialise their
# own `RO_WAS_ENABLED=0`; keeping the name means their existing traps work
# unchanged.
RO_WAS_ENABLED=${RO_WAS_ENABLED:-0}

_RO_LOCK_FILE=/run/steam-machine-rootfs.lock
_RO_LOCK_FD=
# Longest a caller will wait for the lock. The slowest holder is the sensors
# unit, which can pacman-install kernel headers and compile it87 while holding
# it; ten minutes covers that on a cold cache and still leaves room under the
# units' own TimeoutStartSec.
_RO_LOCK_WAIT=${STEAM_MACHINE_ROOTFS_LOCK_WAIT:-600}

_ro_log()  { command -v log  >/dev/null 2>&1 && log  "$@" || printf '==> %s\n' "$*"; }
_ro_warn() { command -v warn >/dev/null 2>&1 && warn "$@" || printf '[warn] %s\n' "$*" >&2; }

# Best effort by design. A machine where the lock cannot be created (not root,
# no /run) is still better served by doing the work unserialised than by
# refusing to run at all -- the lock prevents a race, it is not a permission
# check.
_ro_lock() {
    [[ -n $_RO_LOCK_FD ]] && return 0          # already held by this process
    command -v flock >/dev/null 2>&1 || return 0
    exec {_RO_LOCK_FD}>"$_RO_LOCK_FILE" 2>/dev/null || { _RO_LOCK_FD=; return 0; }
    if ! flock -w "$_RO_LOCK_WAIT" "$_RO_LOCK_FD"; then
        _ro_warn "timed out after ${_RO_LOCK_WAIT}s waiting for $_RO_LOCK_FILE -- continuing unserialised"
        exec {_RO_LOCK_FD}>&-
        _RO_LOCK_FD=
    fi
    return 0
}

_ro_unlock() {
    [[ -n $_RO_LOCK_FD ]] || return 0
    exec {_RO_LOCK_FD}>&-
    _RO_LOCK_FD=
}

unlock_rootfs() {
    command -v steamos-readonly >/dev/null 2>&1 || return 0
    _ro_lock
    # Checked under the lock, never before it: the whole point is that the
    # answer cannot change while we act on it.
    if [[ "$(steamos-readonly status 2>/dev/null)" == "enabled" ]]; then
        RO_WAS_ENABLED=1
        _ro_log "unlocking read-only rootfs"
        if ! steamos-readonly disable; then
            RO_WAS_ENABLED=0
            _ro_unlock
            command -v die >/dev/null 2>&1 && die "could not disable steamos-readonly"
            _ro_warn "could not disable steamos-readonly"
            return 1
        fi
    fi
    return 0
}

# Safe to call twice (traps often fire on top of an explicit call): the flag is
# cleared as soon as the relock is done.
relock_rootfs() {
    if [[ ${RO_WAS_ENABLED:-0} -eq 1 ]]; then
        RO_WAS_ENABLED=0
        _ro_log "restoring read-only rootfs"
        command -v steamos-readonly >/dev/null 2>&1 \
            && { steamos-readonly enable || _ro_warn "could not re-enable read-only rootfs"; }
    fi
    _ro_unlock
    return 0
}
