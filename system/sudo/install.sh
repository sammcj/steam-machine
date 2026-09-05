#!/usr/bin/env bash
# Make sudo's password cache work on this machine.
#
#   ./install.sh              install the drop-in, keep entry and boot unit
#   ./install.sh --boot       restore what a SteamOS update dropped. Run as root
#                             by steam-machine-sudo.service
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall
#
# ---------------------------------------------------------------------------
# THE PROBLEM
#
# sudo's default `timestamp_type` is `tty`: the credential record is keyed on
# the controlling terminal, so authenticating in one terminal does not carry to
# another. Anything running WITHOUT a terminal -- Game Mode, an agent shell, a
# script, a systemd unit -- has no tty to key on, and sudo falls back to keying
# on the PARENT PROCESS ID instead. Every new shell is a new ppid, so the
# record never matches and every sudo re-prompts, five-minute timeout or not.
#
# On this machine that is not a minor annoyance: with no tty there is also no
# terminal to prompt in, so each re-prompt is a ksshaskpass dialog on the TV.
# A three-command sequence means three dialogs.
#
# `timestamp_type=global` keys the record on the user, so one record in
# /run/sudo/ts is shared by every shell that user owns. /run is tmpfs, so the
# cache is still gone at reboot.
#
# WHAT THIS COSTS
#
# For the length of the timeout, ANY process running as deck can run sudo
# without a password -- not just the terminal that authenticated. That is a
# real widening on a multi-user machine. This is a single-user living-room
# console whose only remote access is sshd restricted to `deck` (see
# system/ssh/), and the alternative is a password dialog on the TV per command,
# so the trade is taken deliberately rather than by default. Scoped to `deck`
# with `Defaults:deck` so it is not a machine-wide change.
#
# WHY IT NEEDS A KEEP ENTRY
#
# /etc/sudoers.d is NOT on the SteamOS atomic-update keep list (/etc/passwd,
# /etc/group and /etc/shadow are; the sudoers drop-in directory is not). So the
# drop-in is deleted by the next A/B update, silently, and the only symptom is
# that the password prompts come back.
#
# SAFETY
#
# A malformed file in /etc/sudoers.d breaks sudo for every user -- on a machine
# whose only other route to root is the same sudo. So: validate the candidate
# with `visudo -cf` BEFORE installing it, install under a dotted temp name that
# sudo ignores and rename into place, then re-validate the whole set and roll
# back if that fails. Same shape as system/ssh/, and for the same reason.
# ---------------------------------------------------------------------------
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

TARGET_USER="deck"

# sudo ignores any file in sudoers.d whose name contains a dot, so the
# installed name has no extension even though the repo copy carries .conf.
DROPIN_SRC="$REPO_DIR/sudoers.d/zz-steam-machine.conf"
DROPIN_DEST="/etc/sudoers.d/zz-steam-machine"
# Pre-rename names, removed on sight. See ensure_etc_config.
DROPIN_LEGACY=(/etc/sudoers.d/10-steam-machine /etc/sudoers.d/99-steam-machine)
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-sudo.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-sudo.conf"
UNIT_SRC="$REPO_DIR/systemd/steam-machine-sudo.service"
UNIT_DEST="/etc/systemd/system/steam-machine-sudo.service"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Install the drop-in only if it parses, and only leave it there if the whole
# set still parses afterwards. Returns 0 if it wrote something, 1 if there was
# nothing to do -- so the boot path can skip the reload work.
install_dropin() {
    # Mode and owner, not just content: sudo refuses to read the WHOLE set if
    # any drop-in is group- or world-writable, so a file whose bytes are right
    # at mode 0664 breaks sudo entirely and `cmp` alone calls it fine.
    if cmp -s "$DROPIN_SRC" "$DROPIN_DEST" 2>/dev/null \
       && [[ "$(stat -c '%a %U %G' "$DROPIN_DEST" 2>/dev/null)" == "440 root root" ]]; then
        return 1
    fi

    visudo -cqf "$DROPIN_SRC" \
        || die "$DROPIN_SRC does not parse -- refusing to install it"

    local backup=""
    if [[ -f "$DROPIN_DEST" ]]; then
        backup="$(mktemp)"
        cp -a "$DROPIN_DEST" "$backup"
    fi

    # Written under a dotted temp name first: sudo ignores files with a dot in
    # the name, so a half-written file in sudoers.d is inert rather than
    # dangerous. The rename into place is atomic.
    #
    # Every write is checked. `install_dropin` is called from an `if`, and bash
    # disables `set -e` for the whole dynamic extent of a function called that
    # way -- so without these an `install` or `mv` that failed would fall
    # through, `visudo -cq` would pass against the file still sitting there, and
    # the run would report "restored" having written nothing.
    local tmp="/etc/sudoers.d/.zz-steam-machine.new"
    install -m440 -o root -g root "$DROPIN_SRC" "$tmp" \
        || die "could not write $tmp -- nothing changed"
    mv -f "$tmp" "$DROPIN_DEST" \
        || { rm -f "$tmp"; die "could not install $DROPIN_DEST -- nothing changed"; }

    if ! visudo -cq; then
        warn "the sudoers set does not parse with the new drop-in -- rolling back"
        if [[ -n "$backup" ]]; then
            # The one place a silent failure would matter: a rejected sudoers
            # file left in place is the lockout this whole function exists to
            # prevent, so say so in the loudest terms available.
            cp -a "$backup" "$DROPIN_DEST" \
                || die "COULD NOT ROLL BACK -- delete $DROPIN_DEST from a root shell NOW"
            rm -f "$backup"
        else
            rm -f "$DROPIN_DEST" \
                || die "COULD NOT REMOVE the rejected $DROPIN_DEST -- delete it from a root shell NOW"
        fi
        die "rolled back; nothing changed"
    fi
    [[ -n "$backup" ]] && rm -f "$backup"
    return 0
}

ensure_etc_config() {
    # The sudoers write is the only part that needs visudo. The keep entry and
    # the boot unit are restored regardless -- a missing keep entry is the
    # silent, permanent failure (the next A/B update then deletes the drop-in
    # for good, with no unit left to put it back), so skipping it because a
    # validator is absent would defeat the entire subsystem.
    # The drop-in has been installed under two earlier names (10-, then 99-),
    # both of which sort BEFORE SteamOS's own /etc/sudoers.d/wheel and so lost
    # last-match-wins. Removing them first is not tidiness: a leftover copy
    # defines the same Cmnd_Alias names a second time, which makes the WHOLE
    # sudoers set fail to parse, and install_dropin then correctly rolls the new
    # file straight back out again.
    local legacy
    for legacy in "${DROPIN_LEGACY[@]}"; do
        [[ -f "$legacy" ]] || continue
        rm -f "$legacy" \
            && warn "removed superseded $legacy" \
            || warn "could not remove $legacy -- delete it by hand"
    done
    if command -v visudo >/dev/null 2>&1; then
        if install_dropin; then
            warn "restored $DROPIN_DEST (was missing or modified)"
        fi
    else
        warn "visudo not found -- leaving $DROPIN_DEST alone"
    fi
    if ! cmp -s "$KEEP_SRC" "$KEEP_DEST"; then
        install -Dm644 "$KEEP_SRC" "$KEEP_DEST"
        warn "restored $KEEP_DEST (was missing or modified)"
    fi
    if ! cmp -s "$UNIT_SRC" "$UNIT_DEST"; then
        install -Dm644 "$UNIT_SRC" "$UNIT_DEST"
        warn "restored $UNIT_DEST (was missing or modified)"
        systemctl daemon-reload
    fi
}

do_install() {
    need_root
    command -v visudo >/dev/null || die "visudo not found -- refusing to touch sudoers"
    ensure_etc_config
    systemctl enable steam-machine-sudo.service >/dev/null 2>&1 \
        || warn "could not enable steam-machine-sudo.service"
    log "done"
    echo
    do_status
}

do_boot() {
    need_root --boot
    ensure_etc_config
}

# `sudo -U deck -l` prints the Defaults sudo actually resolved FOR DECK, every
# drop-in merged, so this reports the real outcome rather than re-reading our
# own file and assuming it won.
#
# Not `sudo -V`: that reports the settings for whoever is running it, and these
# are `Defaults:deck` entries -- so `sudo -V` under root reports the unchanged
# compiled-in `tty` / 5 minutes and looks exactly like the drop-in having no
# effect, when it is simply not addressed to root.
# NOTE the `tr -d`: sudo wraps this list to the TERMINAL width (it reads
# TIOCGWINSZ, not stdout), so on an 80-column tty the settings spill onto a
# second physical line and reading only the first reports them as unset --
# precisely the false negative the README warns about, by a different route.
deck_defaults() {
    [[ $EUID -eq 0 ]] || { echo "(re-run with sudo to read)"; return; }
    sudo -U "$TARGET_USER" -l 2>/dev/null \
        | sed -n '/^Matching Defaults entries/,/^$/p' | tail -n +2 | tr -d '\n' | sed 's/^ *//'
}

deck_default() {
    local key="$1" line; line="$(deck_defaults)"
    case "$line" in
        *"(re-run"*) echo "$line"; return ;;
    esac
    printf '%s\n' "$line" | tr ',' '\n' | sed -n "s/^ *${key}=//p" | head -1 \
        | grep . || echo "not set (sudo's default applies)"
}

do_status() {
    printf '%-26s' "sudoers drop-in:"
    if [[ ! -f "$DROPIN_DEST" ]]; then
        echo "MISSING -- every sudo will re-prompt"
    elif cmp -s "$DROPIN_SRC" "$DROPIN_DEST"; then
        echo "$DROPIN_DEST (matches repo)"
    else
        echo "$DROPIN_DEST DIFFERS from the repo copy"
    fi

    printf '%-26s' "parses:"
    if [[ $EUID -eq 0 ]]; then
        visudo -cq 2>/dev/null && echo "yes (whole set)" || echo "NO -- sudo is broken, fix it from a root shell"
    else
        echo "(re-run with sudo to check)"
    fi

    printf '%-26s' "timestamp_type (deck):"
    deck_default timestamp_type
    printf '%-26s' "timestamp_timeout (deck):"
    deck_default timestamp_timeout

    printf '%-26s' "A/B update keep:"
    [[ -f "$KEEP_DEST" ]] && echo "installed" || echo "MISSING (drop-in lost on next OS update)"
    printf '%-26s' "boot unit:"
    systemctl is-enabled steam-machine-sudo.service 2>/dev/null || echo "not installed"

    printf '%-26s' "live cache:"
    if [[ -d /run/sudo/ts ]]; then
        printf '%s record(s) in /run/sudo/ts (cleared at reboot -- tmpfs)\n' \
            "$(ls -1 /run/sudo/ts 2>/dev/null | wc -l)"
    else
        echo "no records yet"
    fi
}

do_uninstall() {
    need_root --uninstall
    systemctl disable --now steam-machine-sudo.service >/dev/null 2>&1 || true
    rm -f "$DROPIN_DEST" "$KEEP_DEST" "$UNIT_DEST"
    systemctl daemon-reload
    visudo -cq || warn "the sudoers set does not parse -- fix it from a root shell NOW"
    log "uninstalled -- sudo is back to per-tty caching"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --boot)       do_boot ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
