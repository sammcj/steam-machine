#!/usr/bin/env bash
# htop configuration for this machine, and the A/B-update entry that keeps it.
#
#   ./install.sh              install config for root and deck (idempotent)
#   ./install.sh --boot       boot-time path: restore config a SteamOS update ate
#   ./install.sh --save       copy deck's live htoprc back into the repo
#   ./install.sh --apply      force repo -> both destinations, overwriting local edits
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall
#
# Installs three files:
#   /etc/htoprc                                          system-wide fallback (root)
#   /etc/atomic-update.conf.d/steam-machine-htop.conf     keeps the above
#   /etc/systemd/system/steam-machine-htop.service        restores both at boot
#
# ...plus ~deck/.config/htop/htoprc, owned by deck.
#
# The /etc files live in an overlayfs with its upper layer in /var, so this
# never needs to unlock the rootfs. root picks the config up via /etc/htoprc
# rather than having its own copy maintained here, so there is one config to
# keep instead of two -- see atomic-update.conf.d/steam-machine-htop.conf for
# htop's full config search order.
#
# Note /root is NOT lost on an OS update: it is a SteamOS offload mount on the
# home partition (/dev/nvme0n1p8[/.steamos/offload/root]), writable regardless
# of steamos-readonly. Only /etc is at risk here.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RC_SRC="$REPO_DIR/htoprc"
ETC_DEST="/etc/htoprc"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-htop.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-htop.conf"
UNIT="steam-machine-htop.service"
UNIT_SRC="$REPO_DIR/systemd/$UNIT"
UNIT_DEST="/etc/systemd/system/$UNIT"

TARGET_USER="deck"
ROOT_RC="/root/.config/htop/htoprc"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"; }

user_home() { getent passwd "$TARGET_USER" | cut -d: -f6; }
user_rc()   { local h; h="$(user_home)"; [[ -n "$h" ]] && printf '%s/.config/htop/htoprc' "$h"; }

# Install the repo config into deck's home, owned by deck. Separate from the
# /etc path because this one must not end up root-owned: htop rewrites its
# config on every clean exit, and a root-owned file in deck's home would make
# every future settings change silently fail to save -- which is one of the two
# ways this went wrong in the first place.
install_user_rc() {
    local dest; dest="$(user_rc)"
    [[ -n "$dest" ]] || { warn "no home directory for $TARGET_USER -- skipping"; return 0; }

    local uid gid
    uid="$(id -u "$TARGET_USER")"
    gid="$(id -g "$TARGET_USER")"

    install -d -o "$uid" -g "$gid" -m 700 "$(dirname "$dest")"
    install -o "$uid" -g "$gid" -m 600 "$RC_SRC" "$dest"
}

do_install() {
    need_root
    [[ -f "$RC_SRC"   ]] || die "missing $RC_SRC"
    [[ -f "$KEEP_SRC" ]] || die "missing $KEEP_SRC"
    [[ -f "$UNIT_SRC" ]] || die "missing $UNIT_SRC"

    log "installing $KEEP_DEST (survives SteamOS A/B updates)"
    install -Dm644 "$KEEP_SRC" "$KEEP_DEST"

    log "installing $UNIT_DEST"
    install -Dm644 "$UNIT_SRC" "$UNIT_DEST"
    systemctl daemon-reload
    systemctl enable "$UNIT" >/dev/null 2>&1 || warn "could not enable $UNIT"

    if cmp -s "$RC_SRC" "$ETC_DEST"; then
        log "$ETC_DEST already up to date"
    else
        install -Dm644 "$RC_SRC" "$ETC_DEST"
        log "installed $ETC_DEST (root and any account without its own config)"
    fi

    # Never clobber deck's live config on a plain install -- it is the file this
    # repo copy came from, and it is the one an interactive htop session edits.
    # --apply is the explicit way to overwrite it.
    local dest; dest="$(user_rc)"
    if [[ -f "$dest" ]]; then
        if cmp -s "$RC_SRC" "$dest"; then
            log "$dest already matches the repo"
        else
            warn "$dest differs from the repo -- left alone"
            warn "  ./install.sh --save   keep the live version (copy it into the repo)"
            warn "  ./install.sh --apply  discard it (overwrite from the repo)"
        fi
    else
        install_user_rc
        log "installed $dest"
    fi

    log "done"
    echo
    do_status
}

# Boot path. /etc/htoprc and the keep entry are restored whenever they differ:
# nothing on the system writes /etc/htoprc, so any difference means an update
# removed it. deck's copy is restored only when *missing* -- /home survives
# updates, so a difference there is a deliberate in-htop tweak, and restoring
# over it every boot would undo exactly the settings this is meant to keep.
do_boot() {
    need_root
    if ! cmp -s "$KEEP_SRC" "$KEEP_DEST"; then
        install -Dm644 "$KEEP_SRC" "$KEEP_DEST"
        warn "restored $KEEP_DEST (was missing or modified)"
    fi
    if ! cmp -s "$RC_SRC" "$ETC_DEST"; then
        install -Dm644 "$RC_SRC" "$ETC_DEST"
        warn "restored $ETC_DEST (was missing or modified)"
    fi
    local dest; dest="$(user_rc)"
    if [[ -n "$dest" && ! -f "$dest" ]]; then
        install_user_rc
        warn "restored $dest (was missing)"
    fi
}

# Capture a session of tweaking. htop only writes its config on a clean exit --
# quit with `q`, not Ctrl-C, or there is nothing here to save.
do_save() {
    local src; src="$(user_rc)"
    [[ -n "$src" && -f "$src" ]] || die "no htoprc at ${src:-<unknown home>} to save"
    if cmp -s "$src" "$RC_SRC"; then
        log "repo already matches $src -- nothing to save"
        return 0
    fi
    install -m644 "$src" "$RC_SRC"
    log "copied $src -> $RC_SRC"
    log "now: sudo ./install.sh --apply   (push it to /etc/htoprc for root)"
    log "and: git add -A system/htop && git commit"
}

# Force the repo version everywhere, including over deck's live config and
# root's shadowing copy.
do_apply() {
    need_root
    install -Dm644 "$RC_SRC" "$ETC_DEST"
    log "wrote $ETC_DEST"
    install_user_rc
    log "wrote $(user_rc)"

    # Once root's htop exits cleanly it writes /root/.config/htop/htoprc, which
    # shadows /etc/htoprc from then on -- /root is an offload mount on the home
    # partition, so nothing ever clears it. Removing it is the only way an
    # updated /etc/htoprc reaches root again.
    if [[ -f "$ROOT_RC" ]]; then
        if rm -f "$ROOT_RC" 2>/dev/null; then
            log "removed $ROOT_RC (was shadowing $ETC_DEST)"
        else
            warn "could not remove $ROOT_RC -- it permanently shadows $ETC_DEST"
        fi
    fi
}

do_status() {
    echo -n "repo config:            "
    [[ -f "$RC_SRC" ]] && echo "$RC_SRC" || echo "MISSING"

    echo -n "/etc/htoprc:            "
    if cmp -s "$RC_SRC" "$ETC_DEST"; then
        echo "installed (matches repo)"
    elif [[ -f "$ETC_DEST" ]]; then
        echo "installed but DIFFERS from repo"
    else
        echo "NOT installed -- root falls back to htop's built-in defaults"
    fi

    local dest; dest="$(user_rc)"
    printf '%-24s' "$TARGET_USER config:"
    if [[ -z "$dest" ]]; then
        echo "no home directory for $TARGET_USER"
    elif cmp -s "$RC_SRC" "$dest"; then
        echo "installed (matches repo)"
    elif [[ -f "$dest" ]]; then
        echo "installed, differs from repo (--save to keep it, --apply to discard)"
    else
        echo "NOT installed"
    fi

    # A root-owned file in deck's home is silent breakage: htop shows the right
    # layout, accepts changes, and discards them on exit with no error.
    if [[ -n "$dest" && -f "$dest" ]]; then
        local owner; owner="$(stat -c '%U' "$dest")"
        if [[ "$owner" != "$TARGET_USER" ]]; then
            warn "$dest is owned by $owner, not $TARGET_USER -- htop cannot save changes to it"
            warn "  fix: sudo ./install.sh --apply"
        fi
    fi

    echo -n "root's own config:      "
    if [[ $EUID -ne 0 ]]; then
        echo "unreadable as $(id -un) -- re-run with sudo"
    elif [[ -f "$ROOT_RC" ]]; then
        echo "$ROOT_RC exists (permanently shadows /etc/htoprc -- use --apply)"
    else
        echo "none -- root is using /etc/htoprc"
    fi

    echo -n "A/B update keep entry:  "
    [[ -f "$KEEP_DEST" ]] && echo "installed" \
        || echo "MISSING (/etc/htoprc will be lost on the next OS update)"

    echo -n "boot restore unit:      "
    if systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
        echo "enabled"
    else
        echo "NOT enabled"
    fi
}

do_uninstall() {
    need_root
    systemctl disable "$UNIT" >/dev/null 2>&1 || true
    rm -f "$ETC_DEST" "$KEEP_DEST" "$UNIT_DEST"
    systemctl daemon-reload
    # deck's own config is left in place: it is in deck's home, it is what an
    # interactive htop session writes, and removing it is not this script's call.
    warn "removed the /etc files -- root is back to htop's built-in defaults"
    warn "$(user_rc) left in place"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --boot)       do_boot ;;
    --save)       do_save ;;
    --apply)      do_apply ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
