#!/usr/bin/env bash
# Build + install the out-of-tree btusb_mt7902 driver for the onboard
# MediaTek MT7902 Bluetooth radio (USB 0e8d:7902) on the Gigabyte
# B850M FORCE WIFI6E V2.
#
#   ./install.sh          full install (deps, build, install, enable at boot)
#   ./install.sh --boot   boot-time path: reinstall from cache if /usr was
#                         reset by a SteamOS update; rebuild only if needed
#   ./install.sh --status report current state and exit
#   ./install.sh --uninstall
#
# Everything authoritative lives under /home (this repo + ~/.cache), because
# SteamOS replaces the whole /usr tree on every A/B update.
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
SRC_DIR="$REPO_DIR/upstream"
CACHE_DIR="${MT7902_CACHE:-/home/deck/.cache/mt7902-bt}"
BUILD_DIR="$CACHE_DIR/build"
MODCACHE_DIR="$CACHE_DIR/modules"

KVER="$(uname -r)"
MODNAME="btusb_mt7902"
FW_NAME="BT_RAM_CODE_MT7902_1_1_hdr.bin"
FW_DEST="/usr/lib/firmware/mediatek/$FW_NAME"
MOD_DEST_DIR="/usr/lib/modules/$KVER/updates"
MODPROBE_DEST="/etc/modprobe.d/mt7902-bt.conf"
SERVICE_DEST="/etc/systemd/system/mt7902-bt.service"
# /etc/modprobe.d is not on SteamOS's default atomic-update keep list, so the
# modprobe config needs an explicit allowlist entry to survive an A/B update.
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-bluetooth.conf"
USB_ID="0e8d:7902"
VID=0e8d
PID=7902

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# need_root() now comes from lib/elevate.sh -- it elevates before dying.
# --- SteamOS read-only rootfs -------------------------------------------------
# unlock_rootfs / relock_rootfs come from lib/rootfs.sh. They hold a repo-wide
# flock for the whole unlock..relock window: steamos-readonly is global state,
# and every subsystem's --boot unit starts in the same second, so without it one
# unit's relock lands in the middle of another's writes. See lib/rootfs.sh.

# --- helpers ------------------------------------------------------------------
device_present() { lsusb -d "$USB_ID" >/dev/null 2>&1; }

module_installed() {
    compgen -G "$MOD_DEST_DIR/$MODNAME.ko*" >/dev/null 2>&1
}

# Hash of the vendored source, so edits to it invalidate the cached build
# instead of silently reinstalling a stale module.
src_hash() {
    find "$SRC_DIR/src" "$SRC_DIR/Makefile" -type f -print0 \
        | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

cached_module() {
    local ko="$MODCACHE_DIR/$KVER/$MODNAME.ko"
    local hf="$MODCACHE_DIR/$KVER/$MODNAME.srchash"
    [[ -f "$ko" && -f "$hf" ]] || return 1
    [[ "$(<"$hf")" == "$(src_hash)" ]]
}

firmware_installed() { [[ -f "$FW_DEST" ]]; }

# NB: not `lsmod | grep -q` -- under `set -o pipefail`, grep -q exits on the
# first match, lsmod dies of SIGPIPE, and the whole pipeline reports failure.
module_loaded() {
    local out
    out="$(lsmod)"
    [[ "$out" == *$'\n'"$MODNAME "* || "$out" == "$MODNAME "* ]]
}

# sysfs paths of the MT7902's USB interfaces, e.g. 1-10:1.0
mt7902_interfaces() {
    local d v p
    for d in /sys/bus/usb/devices/*; do
        [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
        v=$(<"$d/idVendor"); p=$(<"$d/idProduct")
        [[ "$v" == "$VID" && "$p" == "$PID" ]] || continue
        # interfaces are children named <dev>:<cfg>.<intf>
        for i in "$d":*; do
            [[ -d "$i" ]] && basename "$i"
        done
    done
}

# --- dependency install -------------------------------------------------------
# SteamOS ships with the pacman keyring uninitialised -- it isn't meant to be
# used for installing packages -- and an A/B update can reset /etc. Without
# this, `pacman -Sy` dies with:
#   warning: Public keyring not found; have you run 'pacman-key --init'?
#   error: keyring is not writable / required key missing from keyring
ensure_keyring() {
    # Count actual keys rather than testing for a file: pubring.gpg is a
    # 0-byte legacy stub on this system, the real keyring is pubring.kbx, and
    # `pacman-key --list-keys` exits 0 even when the keyring is empty.
    local keycount
    keycount="$(pacman-key --list-keys 2>/dev/null | grep -c '^pub' || true)"
    if [[ "${keycount:-0}" -gt 0 ]]; then
        return 0
    fi

    local keyrings=() k
    for k in archlinux holo; do
        [[ -f "/usr/share/pacman/keyrings/$k.gpg" ]] && keyrings+=("$k")
    done
    [[ ${#keyrings[@]} -gt 0 ]] || { warn "no pacman keyrings found to populate"; return 1; }

    log "initialising pacman keyring (${keyrings[*]})"
    pacman-key --init >/dev/null 2>&1 || { warn "pacman-key --init failed"; return 1; }
    pacman-key --populate "${keyrings[@]}" >/dev/null 2>&1 \
        || { warn "pacman-key --populate failed"; return 1; }
}

install_build_deps() {
    local pkgbase headers missing=()
    pkgbase="$(cat "/usr/lib/modules/$KVER/pkgbase" 2>/dev/null || true)"
    [[ -n "$pkgbase" ]] || die "cannot determine kernel pkgbase for $KVER"
    headers="${pkgbase}-headers"

    [[ -d "/usr/lib/modules/$KVER/build" ]] || missing+=("$headers")
    command -v gcc  >/dev/null 2>&1 || missing+=(gcc)
    command -v make >/dev/null 2>&1 || missing+=(make)

    if [[ ${#missing[@]} -eq 0 ]]; then
        log "build dependencies already present"
        return 0
    fi

    ensure_keyring || return 1

    log "installing build dependencies: ${missing[*]}"
    # -Sy (not -Syu): never trigger a partial system upgrade on SteamOS.
    # Returns non-zero rather than dying, so callers can retry (e.g. at boot
    # before the network is up).
    if ! pacman -Sy --needed --noconfirm "${missing[@]}"; then
        warn "pacman failed; is the network up?"
        return 1
    fi

    if [[ ! -d "/usr/lib/modules/$KVER/build" ]]; then
        warn "$headers installed but /usr/lib/modules/$KVER/build is still missing"
        return 1
    fi
}

# --- build --------------------------------------------------------------------
build_module() {
    log "building $MODNAME for kernel $KVER"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    cp -r "$SRC_DIR/src" "$SRC_DIR/Makefile" "$BUILD_DIR/"

    make -C "$BUILD_DIR" KVER="$KVER" >/dev/null \
        || die "module build failed"

    [[ -f "$BUILD_DIR/$MODNAME.ko" ]] || die "build produced no $MODNAME.ko"

    mkdir -p "$MODCACHE_DIR/$KVER"
    install -Dm644 "$BUILD_DIR/$MODNAME.ko" "$MODCACHE_DIR/$KVER/$MODNAME.ko"
    src_hash > "$MODCACHE_DIR/$KVER/$MODNAME.srchash"
    # Written by root but lives under the user's home; keep it user-owned so
    # it can be inspected and cleaned without sudo.
    chown -R deck:deck "$CACHE_DIR" 2>/dev/null || true
    log "cached module at $MODCACHE_DIR/$KVER/$MODNAME.ko"
}

# --- install ------------------------------------------------------------------
install_firmware() {
    log "installing firmware -> $FW_DEST"
    install -Dm644 "$SRC_DIR/firmware/$FW_NAME" "$FW_DEST"
}

install_module() {
    log "installing module -> $MOD_DEST_DIR/$MODNAME.ko"
    install -Dm644 "$MODCACHE_DIR/$KVER/$MODNAME.ko" "$MOD_DEST_DIR/$MODNAME.ko"
    depmod -a "$KVER"
}

install_system_config() {
    log "installing modprobe + systemd configuration"
    install -Dm644 "$REPO_DIR/modprobe.d/mt7902-bt.conf" "$MODPROBE_DEST"
    install -Dm644 "$REPO_DIR/systemd/mt7902-bt.service" "$SERVICE_DEST"
    install -Dm644 "$REPO_DIR/atomic-update.conf.d/steam-machine-bluetooth.conf" "$KEEP_DEST"
    systemctl daemon-reload
    systemctl enable mt7902-bt.service >/dev/null 2>&1 || warn "could not enable mt7902-bt.service"
}

# Second line of defence behind the atomic-update keep entry. If mt7902-bt.conf
# went missing anyway -- an update that predates the keep entry, or a manual
# delete -- put it back before we bind, rather than limping along on the
# explicit rebind in bind_device().
#
# Cheap and idempotent, so it is safe on the fast path. /etc is an overlayfs
# with its upper layer in /var, writable even when steamos-readonly is enabled,
# so this needs no unlock_rootfs. The systemd unit is deliberately not restored
# here: if it were missing this script would not be running to notice.
ensure_system_config() {
    local src dest
    for src in modprobe.d/mt7902-bt.conf \
               atomic-update.conf.d/steam-machine-bluetooth.conf; do
        case "$src" in
            modprobe.d/*)          dest="$MODPROBE_DEST" ;;
            atomic-update.conf.d/*) dest="$KEEP_DEST" ;;
        esac
        if ! cmp -s "$REPO_DIR/$src" "$dest"; then
            install -Dm644 "$REPO_DIR/$src" "$dest"
            warn "restored $dest (was missing or modified)"
        fi
    done
}

# --- load + bind --------------------------------------------------------------
# The in-tree btusb also matches this device generically and will fail on it
# ("Unsupported hardware variant"). Move it to our module explicitly, so the
# result does not depend on module load order.
bind_device() {
    device_present || { warn "MT7902 ($USB_ID) not present, nothing to bind"; return 0; }

    if ! module_loaded; then
        if ! modprobe "$MODNAME" 2>&1; then
            warn "modprobe $MODNAME failed; check: journalctl -k | grep $MODNAME"
            return 1
        fi
    fi

    if [[ ! -d "/sys/bus/usb/drivers/$MODNAME" ]]; then
        warn "$MODNAME loaded but did not register a USB driver"
        return 1
    fi

    local intf cur moved=0
    for intf in $(mt7902_interfaces); do
        cur=""
        [[ -e "/sys/bus/usb/devices/$intf/driver" ]] \
            && cur="$(basename "$(readlink -f "/sys/bus/usb/devices/$intf/driver")")"

        [[ "$cur" == "$MODNAME" ]] && continue

        if [[ -n "$cur" ]]; then
            echo -n "$intf" > "/sys/bus/usb/drivers/$cur/unbind" 2>/dev/null || true
        fi
        if echo -n "$intf" > "/sys/bus/usb/drivers/$MODNAME/bind" 2>/dev/null; then
            moved=1
        fi
    done
    [[ $moved -eq 1 ]] && log "bound MT7902 interfaces to $MODNAME"
    return 0
}

# --- status -------------------------------------------------------------------
do_status() {
    echo "kernel:            $KVER"
    echo -n "MT7902 present:    "; device_present && echo "yes ($USB_ID)" || echo "NO"
    echo -n "firmware:          "; firmware_installed && echo "$FW_DEST" || echo "MISSING"
    echo -n "module installed:  "; module_installed && echo "yes" || echo "NO"
    echo -n "module cached:     "; cached_module && echo "yes ($KVER)" || echo "no"
    echo -n "module loaded:     "; module_loaded && echo "yes" || echo "no"
    echo -n "modprobe.d config: "; [[ -f "$MODPROBE_DEST" ]] && echo "installed" || echo "MISSING"
    echo -n "A/B update keep:   "
    if [[ -f "$KEEP_DEST" ]]; then
        echo "installed (modprobe.d config will survive OS updates)"
    else
        echo "MISSING (modprobe.d config will be lost on next OS update)"
    fi
    echo "interfaces:"
    local intf cur
    for intf in $(mt7902_interfaces); do
        cur="(unbound)"
        [[ -e "/sys/bus/usb/devices/$intf/driver" ]] \
            && cur="$(basename "$(readlink -f "/sys/bus/usb/devices/$intf/driver")")"
        echo "  $intf -> $cur"
    done
    echo "controllers:"
    hciconfig 2>/dev/null | grep -E '^hci|BD Address' | sed 's/^/  /' || echo "  (hciconfig unavailable)"
}

# --- top level ----------------------------------------------------------------
do_install() {
    need_root
    trap relock_rootfs EXIT
    unlock_rootfs

    if ! cached_module; then
        install_build_deps || die "could not install build dependencies"
        build_module
    else
        log "using cached module for $KVER"
    fi

    install_firmware
    install_module
    install_system_config
    bind_device

    log "done"
    echo
    do_status
}

# Boot path: /usr may have been wiped by a SteamOS update. Reinstall from the
# cache (fast, offline). Only rebuild if the kernel version changed.
do_boot() {
    need_root
    trap relock_rootfs EXIT

    # Before the fast-path exit below: /etc/modprobe.d is not on SteamOS's
    # default keep list, so mt7902-bt.conf can be gone even when the module and
    # firmware are perfectly intact. Both paths through this function must
    # check it, not just the post-update reinstall path.
    ensure_system_config

    if module_installed && firmware_installed; then
        bind_device
        exit 0
    fi

    unlock_rootfs

    if ! cached_module; then
        # Kernel changed (or first run): needs network for headers.
        local tries=0
        until install_build_deps; do
            tries=$((tries + 1))
            [[ $tries -ge 5 ]] && die "giving up waiting for network/pacman"
            warn "retrying dependency install in 30s ($tries/5)"
            sleep 30
        done
        build_module
    fi

    install_firmware
    install_module
    bind_device
    log "restored $MODNAME for kernel $KVER"
}

do_uninstall() {
    need_root
    trap relock_rootfs EXIT
    unlock_rootfs
    systemctl disable --now mt7902-bt.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_DEST" "$MODPROBE_DEST" "$KEEP_DEST"
    systemctl daemon-reload
    rmmod "$MODNAME" 2>/dev/null || true
    rm -f "$MOD_DEST_DIR/$MODNAME.ko" "$FW_DEST"
    depmod -a "$KVER" || true
    log "uninstalled (cache under $CACHE_DIR left in place)"
}

case "${1:-}" in
    ""|--install)  do_install ;;
    --boot)        do_boot ;;
    --status)      do_status ;;
    --uninstall)   do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
