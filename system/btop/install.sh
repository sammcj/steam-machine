#!/usr/bin/env bash
# GPU monitoring for btop on this machine.
#
#   ./install.sh              install the ROCm SMI library and enable the GPU box
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall
#
# btop is built with GPU_SUPPORT=true, but its only AMD backend is the ROCm SMI
# library, which SteamOS does not ship. Without it btop finds no GPU, silently
# drops "gpu0" from shown_boxes on exit, and the GPU box never appears -- which
# looks exactly like the setting not working.
#
# btop does NOT dlopen by soname, so LD_LIBRARY_PATH cannot help. Traced with
# strace, it tries these absolute paths and nothing else:
#
#   /opt/rocm/lib/librocm_smi64.so
#   /usr/lib/librocm_smi64.so
#   /usr/lib/librocm_smi64.so.5
#   /usr/lib/librocm_smi64.so.1.0
#   /usr/lib/librocm_smi64.so.6
#
# /usr is the read-only rootfs an A/B update replaces. /opt is not: it is a
# SteamOS offload mount (/dev/nvme0n1p8[/.steamos/offload/opt]) living on the
# home partition, so it is writable without unlocking the rootfs AND survives
# OS updates on its own. That is why this installs to /opt/rocm/lib and needs
# no atomic-update keep entry or boot self-heal, unlike every other subsystem
# in this repo.
#
# Only librocm_smi64.so is installed, not the rest of the ROCm stack. Checked
# with readelf: it links against libstdc++, libm, libgcc_s and libc only. The
# package's declared dependencies (rocm-core, hsa-rocr, rocm-device-libs, ...)
# are not needed at runtime for monitoring.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PKG="rocm-smi-lib-6.4.1-1-x86_64.pkg.tar.zst"
URL="https://steamdeck-packages.steamos.cloud/archlinux-mirror/extra-3.8/os/x86_64/$PKG"
SHA256="e247384fee905f8798a94d137cf2892938edc9ac80507fb71ab068585f0fbec7"

CACHE_DIR="${BTOP_GPU_CACHE:-/home/deck/.cache/steam-machine-btop}"
PKG_PATH="$CACHE_DIR/$PKG"

LIB_DIR="/opt/rocm/lib"
LIB_REAL="$LIB_DIR/librocm_smi64.so.1.0"

TARGET_USER="deck"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"; }

verify_pkg() { [[ -f "$PKG_PATH" ]] && echo "$SHA256  $PKG_PATH" | sha256sum -c --status; }

fetch_pkg() {
    verify_pkg && { log "using cached $PKG"; return 0; }
    [[ -f "$PKG_PATH" ]] && warn "cached $PKG failed checksum -- re-downloading"
    mkdir -p "$CACHE_DIR"
    log "downloading $PKG"
    curl -fsSL -o "$PKG_PATH.part" "$URL" || die "download failed"
    mv "$PKG_PATH.part" "$PKG_PATH"
    verify_pkg || die "checksum mismatch on $PKG -- refusing to install it"
    chown -R "$TARGET_USER:$TARGET_USER" "$CACHE_DIR" 2>/dev/null || true
}

install_lib() {
    local tmp; tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    tar --zstd -xf "$PKG_PATH" -C "$tmp" opt/rocm/lib/librocm_smi64.so.1.0

    install -Dm755 "$tmp/opt/rocm/lib/librocm_smi64.so.1.0" "$LIB_REAL"
    # btop checks /opt/rocm/lib/librocm_smi64.so first, so the bare symlink is
    # the one that actually matters; .so.1 is the package's own soname chain.
    ln -sfn librocm_smi64.so.1.0 "$LIB_DIR/librocm_smi64.so.1"
    ln -sfn librocm_smi64.so.1   "$LIB_DIR/librocm_smi64.so"
}

# btop rewrites btop.conf on exit, so an edit made while btop is running is
# thrown away. Refuse rather than silently lose the change.
btop_running() { pgrep -x btop >/dev/null 2>&1; }

user_conf() {
    case "$1" in
        root) echo "/root/.config/btop/btop.conf" ;;
        *)    local h; h="$(getent passwd "$1" | cut -d: -f6)"; [[ -n "$h" ]] && echo "$h/.config/btop/btop.conf" ;;
    esac
}

# Add gpu0 to shown_boxes if it isn't already there. btop drops the entry itself
# whenever no GPU is detected, so this is also the repair path after a run made
# before the library was in place.
enable_gpu_box() {
    local conf="$1"
    [[ -n "$conf" && -f "$conf" ]] || return 1

    local cur
    cur="$(sed -n 's/^shown_boxes = "\(.*\)"$/\1/p' "$conf")"
    [[ -n "$cur" ]] || return 1
    if [[ " $cur " == *" gpu0 "* ]]; then
        return 2
    fi

    # Place gpu0 immediately after cpu so the box renders below the CPU box.
    local new
    if [[ " $cur " == *" cpu "* ]]; then
        new="$(echo "$cur" | sed 's/\bcpu\b/cpu gpu0/')"
    else
        new="$cur gpu0"
    fi
    sed -i "s/^shown_boxes = \".*\"$/shown_boxes = \"$new\"/" "$conf"
    return 0
}

apply_conf() {
    local who="$1" conf rc
    conf="$(user_conf "$who")"
    if [[ -z "$conf" || ! -f "$conf" ]]; then
        warn "$who has no btop.conf yet -- run btop once as $who, then re-run this script"
        return 0
    fi
    set +e; enable_gpu_box "$conf"; rc=$?; set -e
    case $rc in
        0) log "enabled the gpu0 box in $conf" ;;
        2) log "$conf already shows the gpu0 box" ;;
        *) warn "could not parse shown_boxes in $conf -- set it by hand (press Esc in btop -> Options)" ;;
    esac
}

do_install() {
    need_root
    if btop_running; then
        die "btop is running -- it rewrites btop.conf on exit and would discard these edits. Quit it first."
    fi

    fetch_pkg
    install_lib
    log "installed $LIB_REAL"

    apply_conf "$TARGET_USER"
    apply_conf root

    log "done"
    echo
    do_status
}

do_status() {
    echo -n "rocm_smi library:       "
    if [[ -f "$LIB_REAL" ]]; then
        echo "installed ($LIB_REAL)"
    else
        echo "NOT installed -- btop will find no GPU"
    fi

    echo -n "btop search path hit:   "
    if [[ -e "$LIB_DIR/librocm_smi64.so" ]]; then
        echo "$LIB_DIR/librocm_smi64.so"
    else
        echo "none of btop's absolute paths exist"
    fi

    # The whole reason this needs no keep entry: confirm /opt really is offloaded
    # to the home partition and not sitting on the rootfs an update replaces.
    echo -n "/opt persistence:       "
    local src; src="$(findmnt -no SOURCE /opt 2>/dev/null || true)"
    if [[ "$src" == *"/.steamos/offload/opt"* ]]; then
        echo "offload mount ($src) -- survives SteamOS updates"
    elif [[ -n "$src" ]]; then
        echo "WARNING: /opt is $src, not the expected offload mount"
    else
        echo "WARNING: /opt is on the rootfs -- this will be lost on the next OS update"
    fi

    local who conf
    for who in "$TARGET_USER" root; do
        printf '%-24s' "$who gpu0 box:"
        conf="$(user_conf "$who")"
        if [[ -z "$conf" ]]; then
            echo "no home directory"
        elif [[ ! -r "$conf" ]]; then
            [[ $EUID -ne 0 && "$who" == root ]] && echo "unreadable as $(id -un) -- re-run with sudo" \
                || echo "no btop.conf yet (run btop once as $who)"
        elif sed -n 's/^shown_boxes = "\(.*\)"$/\1/p' "$conf" | grep -qw gpu0; then
            echo "enabled"
        else
            echo "not shown (btop drops gpu0 when it finds no GPU)"
        fi
    done

    echo -n "GPUs visible to rsmi:   "
    if [[ -f "$LIB_REAL" ]]; then
        # Count real cards, not connectors: /sys/class/drm also holds entries
        # like card1-DP-1 and card1-HDMI-A-1, which a 'card[0-9]*' glob happily
        # counts as GPUs. Anchor on the device link instead.
        local n=0 d
        for d in /sys/class/drm/card[0-9]*; do
            [[ -e "$d/device/driver" ]] || continue
            [[ "$(basename "$(readlink -f "$d/device/driver")")" == "amdgpu" ]] && n=$((n+1))
        done
        echo "$n amdgpu card(s) present"
    else
        echo "n/a"
    fi
}

do_uninstall() {
    need_root
    rm -f "$LIB_DIR/librocm_smi64.so" "$LIB_DIR/librocm_smi64.so.1" "$LIB_REAL"
    rmdir --ignore-fail-on-non-empty "$LIB_DIR" /opt/rocm 2>/dev/null || true
    warn "removed the ROCm SMI library -- btop will drop the GPU box on its next exit"
    warn "cache left at $CACHE_DIR; btop.conf files left alone"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
