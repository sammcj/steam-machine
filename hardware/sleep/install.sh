#!/usr/bin/env bash
# Removal of the keep-awake subsystem. It is gone on purpose -- see ./README.md.
#
#   ./install.sh --uninstall   remove the units, polkit rule and keep entry
#   ./install.sh --status      report what is still installed, change nothing
#
# There is deliberately no --install and no --boot. This subsystem held a logind
# `block` inhibitor on sleep while any SSH session existed, and on 2026-08-18
# that was measured to stop the machine sleeping *permanently* rather than for
# the duration of the session: Steam asks logind to suspend exactly once per
# idle period and does not retry after a refusal, so a single blocked request
# left the machine awake until the Steam client was restarted. The subsystem
# caused strictly more downtime than it prevented.
#
# This script stays in the tree so a machine that still has the old files in
# /etc can be cleaned up, and so `--status` can prove it. It touches only /etc
# and systemd -- it needs none of the deleted repo files to do its job.
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
_l=$(_lib) && source "$_l"

DAEMON_UNIT="steam-machine-keepawake.service"
INHIBIT_UNIT="steam-machine-sleep-inhibit.service"

# The four files the old install.sh dropped into /etc. Listed literally rather
# than derived from the repo, because the sources they were copied from have
# been deleted -- that is the point of this script.
ETC_FILES=(
    "/etc/systemd/system/$DAEMON_UNIT"
    "/etc/systemd/system/$INHIBIT_UNIT"
    "/etc/polkit-1/rules.d/60-steam-machine-inhibit.rules"
    "/etc/atomic-update.conf.d/steam-machine-sleep.conf"
)

BASHRC="/home/deck/.bashrc"
BASHRC_MARKER="# steam-machine: keepawake"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

do_uninstall() {
    need_root --uninstall

    # Order matters. Disabling the daemon does not release the lock -- the lock
    # is held by a separate unit the daemon pulls up, and systemd will leave it
    # running when its starter goes away. Stopping the daemon first only stops
    # anything re-taking it.
    log "stopping $DAEMON_UNIT"
    systemctl disable --now "$DAEMON_UNIT" >/dev/null 2>&1 || true

    log "releasing the sleep inhibitor ($INHIBIT_UNIT)"
    systemctl stop "$INHIBIT_UNIT" >/dev/null 2>&1 || true

    # The units are gone from the repo, so a stale enable symlink pointing at a
    # file that no longer exists would make every later `systemctl daemon-reload`
    # warn. Remove the files, then reload.
    log "removing /etc files"
    rm -f "${ETC_FILES[@]}"
    systemctl daemon-reload
    systemctl reset-failed "$DAEMON_UNIT" "$INHIBIT_UNIT" >/dev/null 2>&1 || true

    log "done -- nothing now blocks logind from suspending this machine"
    echo
    do_status
}

do_status() {
    local f left=0
    echo "installed files (all four should be gone):"
    for f in "${ETC_FILES[@]}"; do
        # The polkit rules directory is 0700 root, so an unprivileged -f test
        # cannot distinguish "absent" from "unreadable" and would report a
        # leftover rule as removed. Say so rather than guess.
        if [[ -e "$f" ]]; then
            printf '  %-58s PRESENT\n' "$f"; left=1
        elif [[ ! -r "$(dirname "$f")" ]]; then
            printf '  %-58s ? (dir unreadable as %s)\n' "$f" "$(id -un)"
        else
            printf '  %-58s removed\n' "$f"
        fi
    done

    echo
    printf '%-24s %s\n' "$DAEMON_UNIT" "$(systemctl is-active "$DAEMON_UNIT" 2>&1)"
    printf '%-24s %s\n' "$INHIBIT_UNIT" "$(systemctl is-active "$INHIBIT_UNIT" 2>&1)"

    echo
    echo "block inhibitors on sleep (any row here stops Steam suspending, and"
    echo "Steam does not retry a refused suspend -- see README.md):"
    systemd-inhibit --list --no-pager 2>/dev/null \
        | awk 'NR==1 || /block/' | sed 's/^/  /' || echo "  (unavailable)"

    if grep -qF "$BASHRC_MARKER" "$BASHRC" 2>/dev/null; then
        echo
        warn "$BASHRC still sources the deleted keepawake.sh -- remove that block"
    fi

    (( left )) && { echo; warn "run: sudo $0 --uninstall"; }
    return 0
}

# NOTE for the root install.sh: it decides which modes a subsystem supports by
# grepping this case block for real arms. Listing an install or boot mode here
# -- even one that only prints an explanation and dies -- would make a
# repo-wide restore run it and count this subsystem as failed. So they are
# absent, not stubbed, and an attempt to use one falls through to the catch-all
# below with the reason.
case "${1:-}" in
    --uninstall) do_uninstall ;;
    --status)    do_status ;;
    *) die "no such mode: ${1:-<none>} -- this subsystem was removed on 2026-08-18 and only
       supports --uninstall and --status. See $(dirname "$0")/README.md" ;;
esac
