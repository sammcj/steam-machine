#!/usr/bin/env bash
# sshd policy for this machine, and the A/B-update entry that keeps it.
#
#   ./install.sh              install config and reload sshd (idempotent)
#   ./install.sh --boot       boot-time path: restore config a SteamOS update ate
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall
#
# Installs three files:
#   /etc/ssh/sshd_config.d/10-steam-machine.conf        access policy + keepalives
#   /etc/atomic-update.conf.d/steam-machine-ssh.conf    keeps the above
#   /etc/systemd/system/steam-machine-ssh.service       restores both at boot
#
# Both live in /etc, an overlayfs with its upper layer in /var, so this never
# needs to unlock the rootfs.
#
# Every path that changes sshd config validates with `sshd -t` first and
# restores the previous file on failure. This is the one service that can lock
# you out of the machine entirely -- there is no other remote way in -- so a
# config that does not parse must never reach a reload.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSHD_SRC="$REPO_DIR/sshd_config.d/10-steam-machine.conf"
SSHD_DEST="/etc/ssh/sshd_config.d/10-steam-machine.conf"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-ssh.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-ssh.conf"
UNIT="steam-machine-ssh.service"
UNIT_SRC="$REPO_DIR/systemd/$UNIT"
UNIT_DEST="/etc/systemd/system/$UNIT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"; }

# Install the drop-in, validate, and roll back if sshd rejects it. Returns 0 if
# nothing changed, 1 if it installed something.
install_sshd_config() {
    if cmp -s "$SSHD_SRC" "$SSHD_DEST"; then
        return 0
    fi

    local backup=""
    if [[ -f "$SSHD_DEST" ]]; then
        backup="$(mktemp)"
        cp -a "$SSHD_DEST" "$backup"
    fi

    install -Dm644 "$SSHD_SRC" "$SSHD_DEST"

    if ! sshd -t 2>/dev/null; then
        if [[ -n "$backup" ]]; then
            cp -a "$backup" "$SSHD_DEST"; rm -f "$backup"
            die "sshd rejected the new config -- rolled back, nothing changed"
        fi
        rm -f "$SSHD_DEST"
        die "sshd rejected $SSHD_SRC -- removed it, nothing changed"
    fi
    [[ -n "$backup" ]] && rm -f "$backup"
    return 1
}

# Reload, never restart. `systemctl reload sshd` re-reads config and applies it
# to NEW connections only; existing sessions -- including the one running this
# script -- are untouched. A restart would drop them.
reload_sshd() {
    if systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl reload sshd && log "sshd reloaded (existing sessions unaffected)"
    else
        warn "sshd is not running -- config installed but not applied"
    fi
}

do_install() {
    need_root
    [[ -f "$SSHD_SRC" ]] || die "missing $SSHD_SRC"
    [[ -f "$KEEP_SRC"  ]] || die "missing $KEEP_SRC"
    [[ -f "$UNIT_SRC"  ]] || die "missing $UNIT_SRC"

    log "installing $KEEP_DEST (survives SteamOS A/B updates)"
    install -Dm644 "$KEEP_SRC" "$KEEP_DEST"

    log "installing $UNIT_DEST"
    install -Dm644 "$UNIT_SRC" "$UNIT_DEST"
    systemctl daemon-reload
    systemctl enable "$UNIT" >/dev/null 2>&1 || warn "could not enable $UNIT"

    if install_sshd_config; then
        log "$SSHD_DEST already up to date"
    else
        log "installed $SSHD_DEST"
        reload_sshd
    fi

    log "done"
    echo
    do_status
}

# Boot path. Neither file is on SteamOS's default keep list, so both can be
# missing after an A/B update -- taking AllowUsers/PermitRootLogin with them.
do_boot() {
    need_root
    if ! cmp -s "$KEEP_SRC" "$KEEP_DEST"; then
        install -Dm644 "$KEEP_SRC" "$KEEP_DEST"
        warn "restored $KEEP_DEST (was missing or modified)"
    fi
    if ! cmp -s "$SSHD_SRC" "$SSHD_DEST"; then
        install_sshd_config || true
        warn "restored $SSHD_DEST (was missing or modified)"
        reload_sshd
    fi
}

do_status() {
    echo -n "sshd drop-in:           "
    if cmp -s "$SSHD_SRC" "$SSHD_DEST"; then
        echo "installed (matches repo)"
    elif [[ -f "$SSHD_DEST" ]]; then
        echo "installed but DIFFERS from repo"
    else
        echo "NOT installed -- access policy has fallen back to Arch defaults"
    fi

    echo -n "A/B update keep entry:  "
    [[ -f "$KEEP_DEST" ]] && echo "installed" \
        || echo "MISSING (sshd policy will be lost on next OS update)"

    echo -n "boot restore unit:      "
    if systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
        echo "enabled"
    else
        echo "NOT enabled"
    fi

    # `sshd -t` reads the host private keys, which are 0600 root:root -- so as
    # an unprivileged user it always fails with "no hostkeys available -- exiting"
    # regardless of whether the config is valid. Reporting that as a broken
    # config is a false alarm on the one service that, if it really were broken,
    # would lock this machine's only remote path.
    echo -n "config parses:          "
    if [[ $EUID -ne 0 ]]; then
        echo "unverifiable as $(id -un) (needs the host keys) -- re-run with sudo"
    elif sshd -t 2>/dev/null; then
        echo "yes"
    else
        echo "NO -- sshd would refuse to start"
        sshd -t 2>&1 | sed 's/^/  /'
    fi

    echo
    if [[ $EUID -ne 0 ]]; then
        echo "effective settings:     (needs root)"
        return 0
    fi
    echo "effective settings:"
    local k
    for k in allowusers permitrootlogin passwordauthentication pubkeyauthentication \
             permitemptypasswords clientaliveinterval clientalivecountmax tcpkeepalive; do
        printf '  %-26s %s\n' "$k" "$(sshd -T 2>/dev/null | awk -v k="$k" '$1==k{$1="";print substr($0,2)}')"
    done
}

do_uninstall() {
    need_root
    systemctl disable "$UNIT" >/dev/null 2>&1 || true
    rm -f "$SSHD_DEST" "$KEEP_DEST" "$UNIT_DEST"
    systemctl daemon-reload
    warn "removed -- sshd access policy is now stock Arch defaults"
    sshd -t 2>/dev/null || die "stock config does not parse; NOT reloading"
    reload_sshd
}

case "${1:-}" in
    ""|--install) do_install ;;
    --boot)       do_boot ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
