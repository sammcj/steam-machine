#!/usr/bin/env bash
# Wake-on-LAN for the onboard Realtek RTL8125D (enp9s0, driver r8169).
#
#   ./install.sh              install config (idempotent). Arms at next boot.
#   ./install.sh --arm-now    ALSO re-run udev now, to arm without rebooting.
#                             Carries a small risk of blipping the link -- see
#                             the warning it prints. Not the default.
#   ./install.sh --boot       boot-time path: restore config an OS update ate
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall
#
# Installs three files:
#   /etc/systemd/network/99-default.link.d/10-wol.conf    arms WoL at udev time
#   /etc/atomic-update.conf.d/steam-machine-network.conf  keeps the above
#   /etc/systemd/system/steam-machine-network.service     restores it at boot
# and sets one NetworkManager property on the wired profile.
#
# Both halves are deliberate; see README.md. Short version: the .link drop-in
# arms WoL at the udev `add` event on every boot regardless of whether any NM
# profile ever activates, and NM's own property survives OS updates for free
# and stops NM tearing the interface down before suspend.
#
# ethtool is not installed on this machine and is not needed -- both paths issue
# the same ETHTOOL_SWOL ioctl that `ethtool -s wol g` would.
#
# This does NOT and cannot configure the BIOS. Wake from S5 additionally needs
# ErP disabled; see README.md.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IFACE="${WOL_IFACE:-enp9s0}"
NM_CONN="${WOL_NM_CONN:-Wired connection 1}"

LINK_SRC="$REPO_DIR/systemd/network/99-default.link.d/10-wol.conf"
LINK_DEST="/etc/systemd/network/99-default.link.d/10-wol.conf"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-network.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-network.conf"
UNIT="steam-machine-network.service"
UNIT_SRC="$REPO_DIR/systemd/$UNIT"
UNIT_DEST="/etc/systemd/system/$UNIT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"; }

pci_addr() {
    basename "$(readlink -f "/sys/class/net/$IFACE/device" 2>/dev/null)" 2>/dev/null
}
sysfs_wakeup() { cat "/sys/class/net/$IFACE/device/power/wakeup" 2>/dev/null || echo "?"; }
mac_addr()     { cat "/sys/class/net/$IFACE/address" 2>/dev/null || echo "?"; }

# Set the NM property without reactivating. `nmcli connection modify` writes the
# profile only; it does not touch the live link, so this is safe to run from an
# SSH session over that very interface. NM applies it on the next activation.
ensure_nm() {
    local cur
    cur="$(nmcli -g 802-3-ethernet.wake-on-lan connection show "$NM_CONN" 2>/dev/null || echo "")"
    if [[ -z "$cur" ]]; then
        warn "NetworkManager profile '$NM_CONN' not found -- skipping the NM half"
        return 0
    fi
    if [[ "$cur" == "magic" ]]; then
        return 0
    fi
    log "setting NM wake-on-lan=magic on '$NM_CONN' (was: $cur)"
    # No wake-on-lan-password: r8169 rejects WAKE_MAGICSECURE with -EINVAL,
    # which would fail the whole ioctl and arm nothing.
    nmcli connection modify "$NM_CONN" \
        802-3-ethernet.wake-on-lan magic \
        802-3-ethernet.wake-on-lan-password "" \
        || warn "nmcli modify failed"
}

# Reinstall anything missing or modified. Returns 0 if unchanged, 1 if it
# restored something.
ensure_etc_config() {
    local changed=0
    if ! cmp -s "$LINK_SRC" "$LINK_DEST"; then
        install -Dm644 "$LINK_SRC" "$LINK_DEST"; warn "restored $LINK_DEST"; changed=1
    fi
    if ! cmp -s "$KEEP_SRC" "$KEEP_DEST"; then
        install -Dm644 "$KEEP_SRC" "$KEEP_DEST"; warn "restored $KEEP_DEST"; changed=1
    fi
    if ! cmp -s "$UNIT_SRC" "$UNIT_DEST"; then
        install -Dm644 "$UNIT_SRC" "$UNIT_DEST"; warn "restored $UNIT_DEST"; changed=1
    fi
    return $changed
}

# Re-run udev's net_setup_link builtin against the live interface so WoL is
# armed without a reboot. Kept behind a flag: this fires an `add` uevent on the
# only interface this machine is reachable over, and while it should be
# non-disruptive (no rename is pending, the name already matches NamePolicy),
# "should be" is doing real work in that sentence.
arm_now() {
    warn "re-triggering udev on $IFACE -- if SSH drops, reconnect; the link should come straight back"
    udevadm control --reload
    udevadm trigger --settle --action=add "/sys/class/net/$IFACE"
    sleep 1
    if [[ "$(sysfs_wakeup)" == "enabled" ]]; then
        log "armed: power/wakeup is now 'enabled'"
    else
        warn "power/wakeup is still '$(sysfs_wakeup)' -- a reboot will apply it"
    fi
}

do_install() {
    local arm=$1
    need_root
    [[ -e "/sys/class/net/$IFACE" ]] || die "no such interface: $IFACE"
    [[ -f "$LINK_SRC" && -f "$KEEP_SRC" && -f "$UNIT_SRC" ]] || die "missing repo files"

    log "installing $LINK_DEST"
    install -Dm644 "$LINK_SRC" "$LINK_DEST"
    log "installing $KEEP_DEST (survives SteamOS A/B updates)"
    install -Dm644 "$KEEP_SRC" "$KEEP_DEST"
    log "installing $UNIT_DEST"
    install -Dm644 "$UNIT_SRC" "$UNIT_DEST"
    systemctl daemon-reload
    systemctl enable "$UNIT" >/dev/null 2>&1 || warn "could not enable $UNIT"

    ensure_nm

    if [[ $arm -eq 1 ]]; then
        arm_now
    else
        log "config installed -- WoL arms on the next boot"
        log "(use --arm-now to apply without rebooting)"
    fi

    log "done"
    echo
    do_status
}

do_boot() {
    need_root
    if ! ensure_etc_config; then
        systemctl daemon-reload || true
        # Honest about what this did and did not fix: udev applied the link
        # configuration long before this unit ran, so restoring the file helps
        # the NEXT boot, not this one. NM's half is not so limited -- it takes
        # effect on the next activation of the profile.
        warn "WoL config was missing and has been restored -- it applies from the next boot"
    fi
    ensure_nm
}

do_status() {
    local addr wake
    addr="$(pci_addr)"; wake="$(sysfs_wakeup)"

    printf 'interface:              %s (%s)\n' "$IFACE" "$(mac_addr)"
    printf 'driver / pci:           %s / %s\n' \
        "$(basename "$(readlink -f "/sys/class/net/$IFACE/device/driver" 2>/dev/null)" 2>/dev/null)" "$addr"
    printf 'link speed:             %s\n' "$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null || echo '?') Mb/s"

    echo
    echo -n ".link drop-in:          "
    if cmp -s "$LINK_SRC" "$LINK_DEST"; then echo "installed (matches repo)"
    elif [[ -f "$LINK_DEST" ]]; then echo "installed but DIFFERS from repo"
    else echo "NOT installed"; fi

    echo -n "A/B update keep entry:  "
    [[ -f "$KEEP_DEST" ]] && echo "installed" || echo "MISSING (drop-in lost on next OS update)"

    echo -n "boot restore unit:      "
    systemctl is-enabled --quiet "$UNIT" 2>/dev/null && echo "enabled" || echo "NOT enabled"

    echo -n "NetworkManager wol:     "
    printf '%s\n' "$(nmcli -g 802-3-ethernet.wake-on-lan connection show "$NM_CONN" 2>/dev/null || echo '?')"

    echo -n "udev link file in use:  "
    udevadm info "/sys/class/net/$IFACE" 2>/dev/null \
        | sed -n 's/^E: ID_NET_LINK_FILE=//p' | head -1 || echo "?"
    echo -n "udev link drop-ins:     "
    udevadm info "/sys/class/net/$IFACE" 2>/dev/null \
        | sed -n 's/^E: ID_NET_LINK_FILE_DROPINS=//p' | head -1 | grep . || echo "(none active)"

    echo
    # This is the one that matters. Everything above is configuration; this is
    # the kernel telling you whether the NIC will actually raise PME. r8169's
    # __rtl8169_set_wol() ends in device_set_wakeup_enable(), so a successful
    # SWOL flips this to `enabled` by itself -- if it still says `disabled`, the
    # ioctl never landed, whatever the config files say.
    printf 'ARMED (power/wakeup):   %s\n' "$wake"
    if [[ "$wake" != "enabled" ]]; then
        echo '                        ^ WoL is NOT active on the running system'
    fi
    printf 'wakeup_count:           %s\n' \
        "$(cat "/sys/class/net/$IFACE/device/power/wakeup_count" 2>/dev/null || true)"
    printf 'acpi wakeup node:       %s\n' "$(rg "$(cut -d: -f2- <<<"$addr" | cut -d. -f1)" /proc/acpi/wakeup 2>/dev/null | head -1 || echo '?')"

    cat <<EOF

BIOS (cannot be checked or set from Linux):
  Settings -> Platform Power -> ErP = Disabled
    ErP cuts the +5V standby rail that keeps the NIC alive in S5, which
    disables WoL entirely. Fastest field test: after 'systemctl poweroff' the
    rear LAN LED must stay lit. Dark LED means ErP is still on.

To wake it, from another machine on this subnet -- broadcast, not unicast:
  wakeonlan -i 192.168.0.255 $(mac_addr)
  (once the box is off its ARP entry expires, so a unicast packet cannot be
  addressed at all)
EOF
}

do_uninstall() {
    need_root
    systemctl disable "$UNIT" >/dev/null 2>&1 || true
    rm -f "$LINK_DEST" "$KEEP_DEST" "$UNIT_DEST"
    rmdir --ignore-fail-on-non-empty "$(dirname "$LINK_DEST")" 2>/dev/null || true
    systemctl daemon-reload
    nmcli connection modify "$NM_CONN" 802-3-ethernet.wake-on-lan default 2>/dev/null \
        || warn "could not reset the NM property"
    warn "removed -- WoL stays armed until the next reboot"
}

case "${1:-}" in
    ""|--install) do_install 0 ;;
    --arm-now)    do_install 1 ;;
    --boot)       do_boot ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
