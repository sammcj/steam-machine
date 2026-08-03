#!/usr/bin/env bash
# Display configuration for the LG C9 on the RX 9070 XT.
#
#   ./install.sh            install config (idempotent)
#   ./install.sh --status   report current state and exit
#   ./install.sh --uninstall
#
# Installs two files:
#   /etc/modprobe.d/amdgpu-display.conf          amdgpu module options
#   /etc/atomic-update.conf.d/steam-machine-display.conf   keeps the above
#                                                across SteamOS A/B updates
#
# Both live in /etc, which is an overlayfs with its upper layer in
# /var/lib/overlays/etc/upper -- writable even when steamos-readonly is
# enabled, so this never needs to unlock the rootfs.
#
# Requires a reboot: amdgpu module parameters are read-only at runtime
# (/sys/module/amdgpu/parameters/* is mode 0444) and amdgpu cannot be reloaded
# while the display is up.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODPROBE_SRC="$REPO_DIR/modprobe.d/amdgpu-display.conf"
MODPROBE_DEST="/etc/modprobe.d/amdgpu-display.conf"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-display.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-display.conf"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"; }

param() { cat "/sys/module/amdgpu/parameters/$1" 2>/dev/null || echo "?"; }

do_install() {
    need_root
    [[ -f "$MODPROBE_SRC" ]] || die "missing $MODPROBE_SRC"
    [[ -f "$KEEP_SRC"     ]] || die "missing $KEEP_SRC"

    log "installing $MODPROBE_DEST"
    install -Dm644 "$MODPROBE_SRC" "$MODPROBE_DEST"

    log "installing $KEEP_DEST (survives SteamOS A/B updates)"
    install -Dm644 "$KEEP_SRC" "$KEEP_DEST"

    # amdgpu is not in the initramfs on this machine, so /etc/modprobe.d is read
    # directly at module load. Warn if that ever stops being true, because then
    # the initramfs would hold a stale copy and this config would be ignored.
    # Resolved from pkgbase, not $(uname -r): Arch names the image after the package (initramfs-linux-neptune-616-drm-exec.img), so the old /boot/initramfs-$(uname -r).img never existed and this guard silently never fired -- lsinitcpio on a missing file prints nothing and grep -q matches nothing.
    local _pkgbase _img
    _pkgbase="$(cat "/usr/lib/modules/$(uname -r)/pkgbase" 2>/dev/null || true)"
    _img="/boot/initramfs-${_pkgbase}.img"
    if [[ -z "$_pkgbase" || ! -f "$_img" ]]; then
        warn "cannot locate the initramfs for $(uname -r) -- skipping the amdgpu-in-initramfs check"
    elif lsinitcpio "$_img" 2>/dev/null | grep -q 'amdgpu\.ko'; then
        warn "amdgpu is now inside the initramfs -- run 'mkinitcpio -P' as well"
    fi

    log "done -- reboot for this to take effect"
    echo
    do_status
}

# Whether VRR is actually engaged, and whether the display is being driven as
# one pipe or two. Both need debugfs, which is root-only.
#
# The ODM part matters because a vertical seam down the centre of the screen was
# once blamed on freesync_pcon_allow_all=1 (see README). It is not caused by
# that parameter: ODM 2:1 combine is on regardless, because 4K120 exceeds what
# one DCN pipe can clock out. Eyeballing the seam is not a measurement; this is.
DBG_DIR="/sys/kernel/debug/dri/0000:03:00.0"

do_pipeline() {
    echo
    if [[ $EUID -ne 0 ]]; then
        echo "VRR / pipe topology:       (needs root -- re-run with sudo -A)"
        return 0
    fi

    local range
    range="$(tr '\n' ' ' < "$DBG_DIR/DP-1/vrr_range" 2>/dev/null || true)"
    echo "VRR:"
    printf '  %-24s %s\n' "sink vrr_range" "${range:-unavailable}"
    if [[ "$range" =~ Min:\ 0\ +Max:\ 0 ]]; then
        printf '  %-24s %s\n' "engaged" "no (sink reports no VRR range)"
    else
        printf '  %-24s %s\n' "engaged" "possibly -- range is non-zero"
    fi

    # One line per active HUBP (display pipe) feeding the surface. Two lines of
    # equal width == ODM 2:1: the frame is split and stitched at the midpoint.
    local dtn active
    dtn="$(cat "$DBG_DIR/amdgpu_dm_dtn_log" 2>/dev/null || true)"
    if [[ -z "$dtn" ]]; then
        echo "pipe topology:             unavailable"
        return 0
    fi

    # The DTN log's row label is "[ 0]:" -- a space inside the brackets, so awk
    # splits it into two fields and every column is shifted by one. Hence $5/$6
    # for width/height and $14 for underflow, not $4/$5 and $13. Three later
    # sections also start with "HUBP:", so the header match is anchored on the
    # "format" column that only the first one has.
    echo "pipe topology:"
    active="$(awk '/^HUBP: +format/{f=1;next} /^[[:space:]]*$/{f=0}
                   f && $5+0 > 0 { idx=$2; sub(/\]:/,"",idx);
                                   printf "  pipe %s  %sx%s\n", idx, $5, $6 }' <<<"$dtn")"
    if [[ -z "$active" ]]; then
        echo "  (no active pipes)"
    else
        printf '%s\n' "$active"
        local n; n="$(grep -c . <<<"$active")"
        if [[ "$n" -ge 2 ]]; then
            printf '  %-24s %s\n' "=>" "ODM ${n}:1 combine -- seam at the stitch point is inherent here"
        else
            printf '  %-24s %s\n' "=>" "single pipe, no ODM"
        fi
    fi

    printf '  %-24s %s\n' "underflow" \
        "$(awk '/^HUBP: +format/{f=1;next} /^[[:space:]]*$/{f=0}
                f && $5+0 > 0 && $14 != "0h" {bad=1}
                END{print bad?"NON-ZERO -- bandwidth problem":"0 (clean)"}' <<<"$dtn")"
}

do_status() {
    echo "kernel:                    $(uname -r)"
    echo -n "modprobe.d config:         "
    if [[ -f "$MODPROBE_DEST" ]] && cmp -s "$MODPROBE_SRC" "$MODPROBE_DEST"; then
        echo "installed (matches repo)"
    elif [[ -f "$MODPROBE_DEST" ]]; then
        echo "installed but DIFFERS from repo"
    else
        echo "NOT installed"
    fi

    echo -n "atomic-update keep entry:  "
    [[ -f "$KEEP_DEST" ]] && echo "installed" || echo "NOT installed (will be lost on OS update)"

    echo
    echo "live amdgpu parameters:"
    printf '  %-26s %s\n' "freesync_pcon_allow_all" "$(param freesync_pcon_allow_all)"
    printf '  %-26s %s\n' "deep_color"              "$(param deep_color)"
    printf '  %-26s %s\n' "dcfeaturemask"           "$(param dcfeaturemask)"

    # Compare the live value against whatever the repo config actually asks for,
    # rather than assuming a particular value is the desired one -- that setting
    # has been flipped once already (see modprobe.d/amdgpu-display.conf).
    local want
    want="$(sed -n 's/^options amdgpu .*freesync_pcon_allow_all=\([0-9]\+\).*/\1/p' \
        "$MODPROBE_SRC" | head -1)"
    if [[ -n "$want" && "$(param freesync_pcon_allow_all)" != "$want" ]]; then
        echo
        warn "config wants freesync_pcon_allow_all=$want but live value is $(param freesync_pcon_allow_all) -- reboot required"
    fi

    echo
    echo "connectors:"
    local c
    for c in /sys/class/drm/card0-*; do
        [[ -f "$c/status" ]] || continue
        printf '  %-24s %s\n' "$(basename "$c")" "$(cat "$c/status")"
    done

    do_pipeline

    echo
    echo "native HDMI 2.1 FRL:       "
    if [[ -f /proc/config.gz ]] || true; then
        echo "  unavailable on this kernel (needs Linux 7.2+; DC_FRL_MASK absent)"
    fi
}

do_uninstall() {
    need_root
    rm -f "$MODPROBE_DEST" "$KEEP_DEST"
    log "removed -- reboot to revert the module parameters"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
