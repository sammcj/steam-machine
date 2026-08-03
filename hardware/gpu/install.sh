#!/usr/bin/env bash
# Keep AMD overdrive enabled across SteamOS A/B updates.
#
# LACT can only expose clock, voltage, power-limit and fan controls when
# amdgpu is loaded with the PP_OVERDRIVE bit (0x4000) set in ppfeaturemask.
# It offers to write /etc/modprobe.d/99-amdgpu-overdrive.conf for you, and that
# works -- until the next OS update deletes it, because /etc/modprobe.d is not
# on SteamOS's keep list. This subsystem is the missing half.
#
#   ./install.sh              install config, keep entry and the boot unit
#   ./install.sh --boot       boot-time path: restore anything a SteamOS update
#                             dropped from /etc. Run as root by the system unit
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall  remove ours *and* LACT's config (overdrive off)
#
# Nothing lands in /usr, which SteamOS replaces wholesale on every A/B update.
# The config goes in /etc (an overlay: survives reboots unconditionally,
# survives updates only via the atomic-update.conf.d entry) and everything else
# lives in this repo under /home.
#
# Requires a reboot: amdgpu module parameters are read-only at runtime
# (/sys/module/amdgpu/parameters/* is mode 0444) and amdgpu cannot be reloaded
# while the display is up.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODPROBE_SRC="$REPO_DIR/modprobe.d/99-amdgpu-overdrive.conf"
MODPROBE_DEST="/etc/modprobe.d/99-amdgpu-overdrive.conf"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-gpu.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-gpu.conf"
UNIT_SRC="$REPO_DIR/systemd/steam-machine-gpu.service"
UNIT_DEST="/etc/systemd/system/steam-machine-gpu.service"

# PP_OVERDRIVE_MASK from drivers/gpu/drm/amd/pm/inc/amd_powerplay.h.
OVERDRIVE_BIT=0x4000

FLATPAK_ID="io.github.ilya_zlobintsev.LACT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A $0 ${1:-})"; }

# --- mask helpers -------------------------------------------------------------
# ppfeaturemask is printed as 0x-prefixed hex by the kernel and written the same
# way by LACT, but case and prefix are not guaranteed -- normalise before doing
# arithmetic on it.
mask_from_file() {
    [[ -f "$1" ]] || return 1
    sed -n 's/.*[[:space:]]ppfeaturemask=\([0-9A-Fa-fxX]\+\).*/\1/p' "$1" | head -1
}

live_mask() { cat /sys/module/amdgpu/parameters/ppfeaturemask 2>/dev/null || true; }

# 0 (true) if the overdrive bit is set in the mask given as $1.
has_overdrive() {
    local m="${1:-}"
    [[ -n "$m" ]] || return 1
    (( ( $((m)) & OVERDRIVE_BIT ) != 0 ))
}

# Compare the installed file to the repo copy by the *value* it sets, not by
# bytes. LACT writes this file with no trailing newline; a future version adding
# one would otherwise be reported as drift forever, which is exactly the kind of
# false alarm that trains you to ignore the real one.
mask_matches_repo() {
    local a b
    a="$(mask_from_file "$MODPROBE_SRC"  || true)"
    b="$(mask_from_file "$MODPROBE_DEST" || true)"
    [[ -n "$a" && -n "$b" ]] || return 1
    (( $((a)) == $((b)) ))
}

# --- /etc self-heal -----------------------------------------------------------
# Cheap and idempotent, so it is safe on the boot fast path. /etc is an
# overlayfs with its upper layer in /var, writable even when steamos-readonly
# is enabled, so this needs no rootfs unlock.
#
# The modprobe config is restored only when *missing*, never when it merely
# differs. LACT owns that file -- it writes it, and rewrites it whenever the
# overdrive toggle is flipped. Overwriting a differing copy would mean fighting
# a future LACT that picks a different mask, and losing silently. A missing file
# is unambiguous: an OS update took it.
ensure_etc_config() {
    if [[ ! -f "$MODPROBE_DEST" ]]; then
        install -Dm644 "$MODPROBE_SRC" "$MODPROBE_DEST"
        warn "restored $MODPROBE_DEST (was missing -- OS update?)"
        warn "overdrive returns after the NEXT reboot, not this boot"
    elif ! mask_matches_repo; then
        warn "$MODPROBE_DEST sets a different mask -- leaving LACT's version alone"
        warn "  repo: $(mask_from_file "$MODPROBE_SRC")   installed: $(mask_from_file "$MODPROBE_DEST")"
    fi

    local src dest
    for src in "$KEEP_SRC" "$UNIT_SRC"; do
        [[ "$src" == "$KEEP_SRC" ]] && dest="$KEEP_DEST" || dest="$UNIT_DEST"
        if ! cmp -s "$src" "$dest"; then
            install -Dm644 "$src" "$dest"
            warn "restored $dest (was missing or modified)"
        fi
    done
}

# --- top level ----------------------------------------------------------------
do_install() {
    need_root

    [[ -f "$MODPROBE_SRC" ]] || die "missing $MODPROBE_SRC"

    log "installing $MODPROBE_DEST"
    if [[ -f "$MODPROBE_DEST" ]] && ! mask_matches_repo; then
        warn "keeping the existing file (LACT's) -- it sets a different mask"
    else
        install -Dm644 "$MODPROBE_SRC" "$MODPROBE_DEST"
    fi

    log "installing $KEEP_DEST (survives SteamOS A/B updates)"
    install -Dm644 "$KEEP_SRC" "$KEEP_DEST"

    log "installing $UNIT_DEST"
    install -Dm644 "$UNIT_SRC" "$UNIT_DEST"
    systemctl daemon-reload
    systemctl enable steam-machine-gpu.service >/dev/null 2>&1 \
        || warn "could not enable steam-machine-gpu.service"

    # amdgpu is not in the initramfs on this machine, so /etc/modprobe.d is read
    # directly at module load and LACT's initramfs regeneration is a no-op here.
    # Warn if that ever stops being true, because then the initramfs would hold
    # a stale copy and this config would be ignored -- and /boot lives on the
    # A/B rootfs, so a regenerated initramfs is discarded by an update anyway.
    # Resolved from pkgbase, not $(uname -r): Arch names the image after the package (initramfs-linux-neptune-616-drm-exec.img), so the old /boot/initramfs-$(uname -r).img never existed and this guard silently never fired -- lsinitcpio on a missing file prints nothing and grep -q matches nothing.
    local _pkgbase _img
    _pkgbase="$(cat "/usr/lib/modules/$(uname -r)/pkgbase" 2>/dev/null || true)"
    _img="/boot/initramfs-${_pkgbase}.img"
    if [[ -z "$_pkgbase" || ! -f "$_img" ]]; then
        warn "cannot locate the initramfs for $(uname -r) -- skipping the amdgpu-in-initramfs check"
    elif lsinitcpio "$_img" 2>/dev/null | grep -q 'amdgpu\.ko'; then
        warn "amdgpu is now inside the initramfs -- run 'mkinitcpio -P' after every update"
    fi

    log "done"
    echo
    do_status
}

do_boot() {
    need_root --boot
    ensure_etc_config
}

do_status() {
    local want live
    want="$(mask_from_file "$MODPROBE_SRC" || true)"
    live="$(live_mask)"

    echo "kernel:                    $(uname -r)"
    echo -n "modprobe.d config:         "
    if [[ ! -f "$MODPROBE_DEST" ]]; then
        echo "NOT installed"
    elif mask_matches_repo; then
        echo "installed (mask matches repo)"
    else
        echo "installed, sets $(mask_from_file "$MODPROBE_DEST") -- repo wants $want"
    fi

    echo -n "atomic-update keep entry:  "
    [[ -f "$KEEP_DEST" ]] && echo "installed" || echo "MISSING (config will be lost on next OS update)"

    echo -n "boot self-heal unit:       "
    if systemctl is-enabled steam-machine-gpu.service >/dev/null 2>&1; then
        echo "enabled"
    else
        echo "NOT enabled"
    fi

    echo
    echo "ppfeaturemask:"
    printf '  %-24s %s\n' "wanted (repo)" "${want:-?}"
    printf '  %-24s %s\n' "live (running kernel)" "${live:-?}"
    printf '  %-24s %s\n' "overdrive bit ($OVERDRIVE_BIT)" \
        "$(has_overdrive "$live" && echo "SET -- LACT controls available" || echo "clear -- LACT controls greyed out")"

    if has_overdrive "$want" && ! has_overdrive "$live"; then
        echo
        warn "config asks for overdrive but the running kernel does not have it -- reboot required"
    fi

    echo
    echo -n "LACT:                      "
    if flatpak info "$FLATPAK_ID" >/dev/null 2>&1; then
        echo "$FLATPAK_ID $(flatpak info "$FLATPAK_ID" 2>/dev/null | sed -n 's/^ *Version: *//p')"
    else
        echo "not installed as a Flatpak"
    fi
    echo -n "lactd.service:             "
    systemctl is-active lactd.service 2>/dev/null || true
}

do_uninstall() {
    need_root --uninstall
    systemctl disable --now steam-machine-gpu.service >/dev/null 2>&1 || true
    # LACT's file goes too: leaving it would keep overdrive on while claiming to
    # have uninstalled, and it is the same file either way.
    rm -f "$MODPROBE_DEST" "$KEEP_DEST" "$UNIT_DEST"
    systemctl daemon-reload
    log "uninstalled -- reboot to drop back to the stock ppfeaturemask"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --boot)       do_boot ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
