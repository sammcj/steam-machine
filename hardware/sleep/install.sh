#!/usr/bin/env bash
# Keep the machine awake while it is being worked on remotely.
#
#   ./install.sh              install and start (idempotent)
#   ./install.sh --boot       boot-time path: restore /etc config that a
#                             SteamOS update may have eaten
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall
#
# Installs four things:
#   /etc/systemd/system/steam-machine-keepawake.service       the daemon
#   /etc/systemd/system/steam-machine-sleep-inhibit.service   the lock holder
#   /etc/polkit-1/rules.d/60-steam-machine-inhibit.rules      lets deck inhibit
#   /etc/atomic-update.conf.d/steam-machine-sleep.conf        keeps the above
# plus one `source` line in ~/.bashrc for the `keepawake` shell function.
#
# Everything lands in /etc, an overlayfs whose upper layer lives in
# /var/lib/overlays/etc/upper -- writable even when steamos-readonly is
# enabled, so this never unlocks the rootfs. The daemon itself runs straight
# out of this repo under /home, which no OS update touches.
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


REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DAEMON_UNIT="steam-machine-keepawake.service"
INHIBIT_UNIT="steam-machine-sleep-inhibit.service"
POLKIT_RULE="/etc/polkit-1/rules.d/60-steam-machine-inhibit.rules"
KEEP_CONF="/etc/atomic-update.conf.d/steam-machine-sleep.conf"
BASHRC="/home/deck/.bashrc"
BASHRC_SNIPPET="$REPO_DIR/bashrc.d/keepawake.sh"
BASHRC_MARKER="# steam-machine: keepawake"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# need_root() now comes from lib/elevate.sh -- it elevates before dying.
# repo-relative source -> absolute destination, for everything dropped in /etc.
#
# The two units are listed even though /etc/systemd/system/*.service is already
# on SteamOS's default keep list. Restoring them costs a cmp against two small
# files, and the alternative -- assuming they are there -- is how you end up
# debugging a missing daemon after a botched update.
declare -A ETC_CONFIG=(
    ["systemd/$DAEMON_UNIT"]="/etc/systemd/system/$DAEMON_UNIT"
    ["systemd/$INHIBIT_UNIT"]="/etc/systemd/system/$INHIBIT_UNIT"
    ["polkit-1/rules.d/60-steam-machine-inhibit.rules"]="$POLKIT_RULE"
    ["atomic-update.conf.d/steam-machine-sleep.conf"]="$KEEP_CONF"
)

# Reinstall anything missing or modified. Cheap and idempotent, so it is safe
# on the boot fast path. Returns 0 if it changed nothing, 1 if it restored
# something -- the caller decides whether that warrants a daemon-reload.
ensure_etc_config() {
    local src changed=0
    for src in "${!ETC_CONFIG[@]}"; do
        if ! cmp -s "$REPO_DIR/$src" "${ETC_CONFIG[$src]}"; then
            install -Dm644 "$REPO_DIR/$src" "${ETC_CONFIG[$src]}"
            warn "restored ${ETC_CONFIG[$src]} (was missing or modified)"
            changed=1
        fi
    done
    return $changed
}

# The shell function is sourced from the repo rather than copied into .bashrc,
# so editing bashrc.d/keepawake.sh takes effect in the next shell with no
# reinstall. Guarded by a marker comment so this stays idempotent.
ensure_bashrc() {
    [[ -f "$BASHRC" ]] || { warn "$BASHRC does not exist -- skipping shell function"; return 0; }
    if grep -qF "$BASHRC_MARKER" "$BASHRC"; then
        return 0
    fi
    log "adding keepawake shell function to $BASHRC"
    printf '\n%s\n[[ -f %s ]] && . %s\n' \
        "$BASHRC_MARKER" "$BASHRC_SNIPPET" "$BASHRC_SNIPPET" >> "$BASHRC"
    chown deck:deck "$BASHRC" 2>/dev/null || true
}

do_install() {
    need_root
    local src
    for src in "${!ETC_CONFIG[@]}"; do
        [[ -f "$REPO_DIR/$src" ]] || die "missing $REPO_DIR/$src"
    done
    [[ -x "$REPO_DIR/bin/keepawake-daemon" ]] || die "bin/keepawake-daemon is not executable"

    log "installing units, polkit rule and A/B update keep entry"
    for src in "${!ETC_CONFIG[@]}"; do
        install -Dm644 "$REPO_DIR/$src" "${ETC_CONFIG[$src]}"
    done

    ensure_bashrc

    systemctl daemon-reload
    log "enabling and (re)starting $DAEMON_UNIT"
    systemctl enable "$DAEMON_UNIT"
    # restart, NOT `enable --now`. `--now` degrades to `start`, which is a no-op
    # on an already-active unit -- so re-running the installer after editing
    # KEEPAWAKE_WINDOW left the old value live in the running process while
    # --status happily reported the new one from the unit file. Caught on
    # 2026-08-03 when the 7200 -> 1800 change appeared to apply and had not.
    #
    # The restart drops the inhibitor for well under a second: the daemon's
    # ExecStopPost stops the inhibit unit, and the new process re-acquires on
    # its first loop iteration, which runs before the first poll sleep. Steam's
    # suspend needs 30 minutes of inactivity, so the gap cannot lose a race.
    systemctl restart "$DAEMON_UNIT"

    # Let the daemon's first loop iteration finish before do_status looks at the
    # lock. Without this the installer's own status block races the restart and
    # prints "sleep currently held: no" with sessions plainly open -- which reads
    # as a broken subsystem at exactly the moment someone is checking it worked.
    #
    # A full timeout is not an error: it is also what a correct run looks like
    # when there are no SSH sessions, which is the common case on the TV.
    local i
    for i in 1 2 3 4 5; do
        systemctl is-active --quiet "$INHIBIT_UNIT" && break
        # `sleep` is unavailable in some non-interactive contexts on this box.
        timeout 1 tail -f /dev/null || true
    done

    log "done"
    echo
    do_status
}

# Boot path, run from the daemon unit's ExecStartPre. /etc/polkit-1/rules.d is
# not on the atomic-update keep list, so the rule is the thing that actually
# goes missing; the units are covered by the default list and are checked here
# only for completeness. Deliberately does NOT restart the daemon -- systemd is
# about to start it anyway, and restarting from within its own ExecStartPre
# would deadlock.
do_boot() {
    need_root
    if ! ensure_etc_config; then
        # polkit reloads rules.d automatically on change (it watches the
        # directory), so there is nothing to poke. daemon-reload is needed
        # only if a unit file itself was restored.
        systemctl daemon-reload || true
    fi
    ensure_bashrc
}

# The grace window the RUNNING daemon actually has, or empty.
#
# The daemon prints `started (window=Ns poll=Ns)` as its first act, so the
# journal holds the value the process was given. Filtering on _PID pins it to
# the current instance -- without that, an old line from a previous PID would be
# reported as current, which is precisely the failure this exists to catch.
running_window() {
    local pid
    pid="$(systemctl show "$DAEMON_UNIT" -p MainPID --value 2>/dev/null || true)"
    [[ -n "$pid" && "$pid" != "0" ]] || return 1
    journalctl -u "$DAEMON_UNIT" _PID="$pid" --no-pager -o cat 2>/dev/null \
        | sed -n 's/^keepawake: started (window=\([0-9]\{1,\}\)s.*/\1/p' \
        | tail -1
}

do_status() {
    local src missing=0

    echo -n "daemon unit:            "
    if systemctl is-enabled --quiet "$DAEMON_UNIT" 2>/dev/null; then
        echo "enabled, $(systemctl is-active "$DAEMON_UNIT" 2>/dev/null)"
    else
        echo "NOT enabled"
    fi

    echo -n "sleep currently held:   "
    if systemctl is-active --quiet "$INHIBIT_UNIT" 2>/dev/null; then
        echo "yes (automatic -- an SSH session is open or within the grace window)"
    else
        echo "no"
    fi

    # Two windows, deliberately. Reporting only the configured one is how a
    # 7200 -> 1800 edit was able to look applied while the daemon carried on
    # with 7200 (see the restart comment in do_install). A status line that
    # confirms a change which did not happen is worse than no status line.
    #
    # Configured: read from the repo unit rather than `systemctl show`, so this
    # still reports something useful when the unit is not loaded at all.
    # Running: taken from the line the daemon itself logs at startup, filtered
    # to the current MainPID. That is the only source that reflects the process
    # rather than the file -- `systemctl show -p Environment` re-reads the unit
    # after a daemon-reload and would tell the same lie.
    local window running
    window="$(sed -n 's/^Environment=KEEPAWAKE_WINDOW=\(.*\)/\1/p' \
        "$REPO_DIR/systemd/$DAEMON_UNIT" | head -1)"
    running="$(running_window || true)"

    printf 'grace window (config):  %s\n' "${window:-unknown} seconds after the last SSH session"
    if [[ -n "$running" ]]; then
        printf 'grace window (running): %s seconds\n' "$running"
    else
        printf 'grace window (running): unknown (daemon stopped, or no start line in the journal)\n'
    fi
    if [[ -n "$window" && -n "$running" && "$window" != "$running" ]]; then
        warn "the running daemon still has the OLD window ($running s, config says $window s)"
        warn "  fix: systemctl restart $DAEMON_UNIT"
    fi

    # /etc/polkit-1/rules.d is 0750 root:polkitd, so an unprivileged `[[ -f ]]`
    # on anything inside it returns false whether or not the file exists.
    # Reporting that as "NOT installed" is a false negative that sends you
    # reinstalling something already in place -- check readability first.
    echo -n "polkit rule:            "
    if [[ ! -r "$(dirname "$POLKIT_RULE")" ]]; then
        echo "unverifiable as $(id -un) -- re-run with sudo"
    elif [[ -f "$POLKIT_RULE" ]] && cmp -s "$REPO_DIR/polkit-1/rules.d/60-steam-machine-inhibit.rules" "$POLKIT_RULE"; then
        echo "installed (deck can inhibit without a password prompt)"
    elif [[ -f "$POLKIT_RULE" ]]; then
        echo "installed but DIFFERS from repo"
    else
        echo "NOT installed -- 'keepawake' will hang on a password prompt"
    fi

    echo -n "A/B update keep entry:  "
    [[ -f "$KEEP_CONF" ]] && echo "installed" \
        || echo "MISSING (polkit rule will be lost on next OS update)"

    echo -n "bashrc hook:            "
    if [[ -f "$BASHRC" ]] && grep -qF "$BASHRC_MARKER" "$BASHRC"; then
        echo "present"
    else
        echo "NOT present"
    fi

    # Same readability caveat as above: only report a file missing when its
    # directory could actually be read, otherwise every non-root --status run
    # prints a spurious MISSING line for the polkit rule.
    local dest unverifiable=0
    for src in "${!ETC_CONFIG[@]}"; do
        dest="${ETC_CONFIG[$src]}"
        [[ -f "$dest" ]] && continue
        if [[ ! -r "$(dirname "$dest")" ]]; then
            unverifiable=1
            continue
        fi
        printf '  MISSING: %s\n' "$dest"
        missing=1
    done
    if [[ $missing -eq 1 ]]; then
        warn "re-run ./install.sh (or reboot: --boot restores these)"
    fi
    if [[ $unverifiable -eq 1 ]]; then
        echo "  (some paths not readable as $(id -un); re-run with sudo to check them)"
    fi

    echo
    echo "logind sleep inhibitors:"
    systemd-inhibit --list 2>/dev/null | awk 'NR==1 || /sleep/' | sed 's/^/  /'

    echo
    echo "ssh sessions logind knows about:"
    local id svc found=0
    while read -r id _; do
        [[ -n "$id" ]] || continue
        svc="$(loginctl show-session "$id" -p Service --value 2>/dev/null || true)"
        if [[ "$svc" == "sshd" ]]; then
            printf '  session %-4s %s\n' "$id" \
                "$(loginctl show-session "$id" -p RemoteHost --value 2>/dev/null)"
            found=1
        fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    # Explicit `if`, not `[[ ... ]] && echo`: this is the last statement in the
    # function, so a false test would make do_status -- and therefore
    # do_install, which ends by calling it -- exit non-zero under `set -e`.
    if [[ $found -eq 0 ]]; then
        echo "  (none)"
    fi
}

do_uninstall() {
    need_root
    systemctl disable --now "$DAEMON_UNIT" >/dev/null 2>&1 || true
    systemctl stop "$INHIBIT_UNIT" >/dev/null 2>&1 || true
    rm -f "${ETC_CONFIG[@]}"
    systemctl daemon-reload
    log "removed units, polkit rule and keep entry"
    warn "the '$BASHRC_MARKER' block in $BASHRC is left in place -- remove it by hand"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --boot)       do_boot ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
