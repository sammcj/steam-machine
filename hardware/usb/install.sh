#!/usr/bin/env bash
# Stop a USB hub error storm from taking the xHCI controller down with it.
# See ./README.md.
#
#   ./install.sh              full setup (udev rule, keep entry, units, shell fn)
#   ./install.sh --status     report current state and exit
#   ./install.sh --boot       boot-time path: reinstall anything a SteamOS
#                             update dropped. The udev rule is not on the
#                             default /etc keep list
#   ./install.sh --uninstall  remove everything this installed
#
# WHAT THIS SUBSYSTEM IS FOR
#
# On 2026-09-05 a reset storm on one hub port took down every USB device on
# bus 5 -- mouse, both keyboards, the USB NIC and two card readers -- and then
# left the controller permanently unable to runtime-suspend:
#
#   usb 5-2.1-port3: cannot reset (err = -71)        <- one port
#   usb 5-2: USB disconnect, device number 2         <- the entire tree
#   hub 5-2:1.0: config failed, can't get hub status (err -5)
#   xhci_hcd 0000:12:00.4: Controller Save State failed -110
#
# after which power/runtime_status read "error" and stayed there. Two parts:
#
#   1. udev.rules.d/  pins power/control=on on every xHCI controller, so the
#      suspend that poisons the device never runs. Prevention.
#   2. systemd/steam-machine-usb-watchdog.service watches for the error state
#      anyway and rebuilds the controller when it appears. Cure, because the
#      rule cannot help a controller that wedges some other way.
#
# bin/usb-reset.sh is the same recovery by hand, exposed to the deck user as
# `usb-reset` through bashrc.d/.
#
# What this does NOT do is stop one bad device taking its siblings down. USB
# port events are processed serially per bus and a hub reset disconnects every
# child; no kernel knob changes that. That part is physical -- see README.md.
set -euo pipefail

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

UDEV_SRC="$REPO_DIR/udev.rules.d/60-steam-machine-usb.rules"
UDEV_DEST="/etc/udev/rules.d/60-steam-machine-usb.rules"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-usb.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-usb.conf"

BOOT_UNIT="steam-machine-usb.service"
WATCHDOG_UNIT="steam-machine-usb-watchdog.service"
UNITS=("$BOOT_UNIT" "$WATCHDOG_UNIT")
UNIT_DIR="/etc/systemd/system"

BASHRC="/home/deck/.bashrc"
BASHRC_SNIPPET="$REPO_DIR/bashrc.d/usb-reset.sh"
BASHRC_MARKER="# steam-machine: usb-reset"

PCI_CLASS_XHCI=0x0c0330

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

controllers() {
    local d
    for d in /sys/bus/pci/devices/*/; do
        [[ -r "$d/class" ]] || continue
        [[ "$(cat "$d/class")" == "$PCI_CLASS_XHCI" ]] && basename "$d"
    done
}

# --- install steps ------------------------------------------------------------
#
# Every ensure_* is idempotent and reports only when it changes something, so
# --boot is quiet on a healthy boot and loud when it actually repaired.

ensure_file() {
    local src=$1 dest=$2 what=$3
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        return 1
    fi
    log "installing $what -> $dest"
    install -Dm644 "$src" "$dest"
    return 0
}

ensure_udev() {
    ensure_file "$UDEV_SRC" "$UDEV_DEST" "udev rule" || return 1
    udevadm control --reload-rules
    # `trigger` re-runs the rule against controllers that already exist, so the
    # pin applies now rather than at the next boot.
    udevadm trigger --subsystem-match=pci --action=add
    return 0
}

ensure_keep() { ensure_file "$KEEP_SRC" "$KEEP_DEST" "atomic-update keep entry"; }

ensure_units() {
    local u changed=1
    for u in "${UNITS[@]}"; do
        ensure_file "$REPO_DIR/systemd/$u" "$UNIT_DIR/$u" "$u" && changed=0
    done
    [[ $changed -eq 0 ]] && systemctl daemon-reload
    return $changed
}

ensure_enabled() {
    local u changed=1
    for u in "${UNITS[@]}"; do
        if ! systemctl is-enabled --quiet "$u" 2>/dev/null; then
            log "enabling $u"
            systemctl enable --quiet "$u"
            changed=0
        fi
    done
    # Only the watchdog is worth having running right now; the boot unit is a
    # oneshot whose work this script has just done directly.
    #
    # restart, not start. The unit runs bin/usb-watchdog.sh straight out of the
    # repo, so an edit to the script changes nothing in an already-running
    # process -- and `is-active` says "active" either way. An install that left
    # the old code running is exactly what happened on 2026-09-05: the trigger
    # bug was fixed, install.sh reported success, and the buggy loop was still
    # the one deciding whether to reset the bus. The loop is stateless (it
    # rebuilds its recovery window from scratch), so a restart costs nothing.
    if [[ ${RESTART_WATCHDOG:-1} -eq 1 ]]; then
        log "restarting $WATCHDOG_UNIT (picks up any script change)"
        systemctl restart "$WATCHDOG_UNIT" || warn "could not restart $WATCHDOG_UNIT"
        changed=0
    elif ! systemctl is-active --quiet "$WATCHDOG_UNIT"; then
        log "starting $WATCHDOG_UNIT"
        systemctl start "$WATCHDOG_UNIT" || warn "could not start $WATCHDOG_UNIT"
        changed=0
    fi
    return $changed
}

# Belt and braces on top of the udev rule: a controller that already exists and
# was not caught by `udevadm trigger` still gets pinned.
ensure_pinned() {
    local addr changed=1
    for addr in $(controllers); do
        local f="/sys/bus/pci/devices/$addr/power/control"
        [[ -w "$f" ]] || continue
        if [[ "$(cat "$f")" != on ]]; then
            log "pinning $addr power/control=on"
            echo on > "$f"
            changed=0
        fi
    done
    return $changed
}

# Sourced from the repo rather than copied into .bashrc, so editing
# bashrc.d/usb-reset.sh takes effect in the next shell with no reinstall.
ensure_bashrc() {
    [[ -f "$BASHRC" ]] || { warn "$BASHRC does not exist -- skipping shell function"; return 1; }
    grep -qF "$BASHRC_MARKER" "$BASHRC" && return 1
    log "adding usb-reset shell function to $BASHRC"
    printf '\n%s\n[[ -f %s ]] && . %s\n' \
        "$BASHRC_MARKER" "$BASHRC_SNIPPET" "$BASHRC_SNIPPET" >> "$BASHRC"
    chown deck:deck "$BASHRC" 2>/dev/null || true
    return 0
}

# --- modes --------------------------------------------------------------------

do_install() {
    need_root
    ensure_udev    || true
    ensure_keep    || true
    ensure_units   || true
    ensure_enabled || true
    ensure_pinned  || true
    ensure_bashrc  || true
    echo
    do_status
    echo
    log "done. \`usb-reset status\` in a new shell, or: $REPO_DIR/bin/usb-reset.sh --status"
}

# The self-heal. Runs before any fast-path exit on purpose: /etc/udev/rules.d is
# NOT on SteamOS's default keep list, so the rule is the thing most likely to be
# missing after an A/B update, and the symptom of losing it (a controller that
# wedges again months later) is invisible.
do_boot() {
    need_root
    local repaired=1
    ensure_udev    && repaired=0
    ensure_keep    && repaired=0
    ensure_units   && repaired=0
    # A healthy boot must not bounce a watchdog that is already running fine,
    # so --boot only starts a stopped one. do_install restarts unconditionally
    # because that is the path taken after editing the scripts.
    RESTART_WATCHDOG=0 ensure_enabled && repaired=0
    ensure_pinned  && repaired=0
    if [[ $repaired -eq 0 ]]; then
        log "repaired after a SteamOS update"
    else
        log "USB runtime-PM pin intact -- nothing to do"
    fi
}

do_status() {
    local ok
    printf '\033[1m%-36s %s\033[0m\n' COMPONENT STATE

    ok=$([[ -f "$UDEV_DEST" ]] && cmp -s "$UDEV_SRC" "$UDEV_DEST" && echo installed || echo MISSING)
    printf '%-36s %s\n' "udev rule" "$ok"
    ok=$([[ -f "$KEEP_DEST" ]] && cmp -s "$KEEP_SRC" "$KEEP_DEST" && echo installed || echo MISSING)
    printf '%-36s %s\n' "atomic-update keep entry" "$ok"

    # `systemctl is-enabled` prints "not-found" on stdout *and* exits non-zero
    # for a unit that does not exist, so `|| echo ...` appends a second value
    # and the row comes out mangled. Capture, then substitute only if empty.
    local u en ac
    for u in "${UNITS[@]}"; do
        en=$(systemctl is-enabled "$u" 2>/dev/null) || true; en=${en:-unknown}
        ac=$(systemctl is-active  "$u" 2>/dev/null) || true; ac=${ac:-unknown}
        printf '%-36s %s / %s\n' "$u" "$en" "$ac"
    done

    echo
    "$REPO_DIR/bin/usb-reset.sh" --status
}

do_uninstall() {
    need_root
    local u
    for u in "${UNITS[@]}"; do
        systemctl disable --now --quiet "$u" 2>/dev/null || true
        rm -f "$UNIT_DIR/$u"
    done
    systemctl daemon-reload
    rm -f "$UDEV_DEST" "$KEEP_DEST"
    udevadm control --reload-rules
    log "removed units, udev rule and keep entry"
    # Deliberately NOT reverting power/control to auto: the controllers are
    # already `on` this boot and writing `auto` back would re-arm the suspend
    # that poisons them, on a machine that is still running. The next reboot
    # restores the kernel default with the rule gone.
    warn "power/control is left at 'on' until the next reboot -- see the note in --uninstall"
    if grep -qF "$BASHRC_MARKER" "$BASHRC" 2>/dev/null; then
        warn "the usb-reset shell function is still sourced from $BASHRC -- remove the two lines after '$BASHRC_MARKER'"
    fi
}

case "${1:---install}" in
    --install|"") do_install ;;
    --boot)       do_boot ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    -h|--help)    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ;;
    *)            die "unknown option: $1 (try --help)" ;;
esac
