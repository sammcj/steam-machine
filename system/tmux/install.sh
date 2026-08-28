#!/usr/bin/env bash
# Keep tmux sessions alive across an SSH disconnect. See ./README.md.
#
#   ./install.sh              install the user unit, the shell wrapper, linger
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall  remove the unit and the linger flag
#
# Installs:
#   ~/.config/systemd/user/steam-machine-tmux.service   symlink into this repo
#   one source line in ~/.bashrc for bashrc.d/tmux.sh
#   linger for `deck`                                   (the only root step)
#
# There is no --boot mode and no atomic-update keep entry, which is the
# exception in this repo rather than the rule. Nothing lands in /etc or /usr:
# the unit and the shell hook are under /home (nvme0n1p8) and the linger flag
# is /var/lib/systemd/linger/deck (nvme0n1p6). Both are their own partitions
# and a SteamOS A/B update replaces neither. Verified with `findmnt -T`.
#
# Root is needed for exactly one command, `loginctl enable-linger deck`, and it
# is invoked on its own rather than via lib/elevate.sh. Re-running the whole
# script as root would create the symlink and edit ~/.bashrc as root, leaving
# root-owned files in /home/deck -- a worse outcome than a missing linger flag.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UNIT="steam-machine-tmux.service"
UNIT_SRC="$REPO_DIR/systemd/$UNIT"
USER_UNIT_DIR="/home/deck/.config/systemd/user"
UNIT_DEST="$USER_UNIT_DIR/$UNIT"

BASHRC="${STEAM_MACHINE_BASHRC:-/home/deck/.bashrc}"
BASHRC_SNIPPET="$REPO_DIR/bashrc.d/tmux.sh"
BASHRC_MARKER="# steam-machine: tmux"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# `systemctl --user` as root talks to root's own manager, not deck's, so every
# answer would be wrong rather than merely unavailable. The repo's top-level
# install.sh runs each subsystem as root for --status, so this is a real case.
usysctl() {
    if [[ $EUID -eq 0 ]]; then
        runuser -u deck -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user "$@"
    else
        systemctl --user "$@"
    fi
}

# Which cgroup is the running tmux server in? This is the whole diagnosis in
# one line: a path containing session-N.scope is the broken case, one under
# user@1000.service is the fixed one. Empty means no server.
server_cgroup() {
    local p ppid
    # Not `pgrep -x tmux`: the server rewrites its argv to "tmux: server", so
    # its comm is not an exact match and -x finds nothing at all.
    for p in $(pgrep -u deck tmux 2>/dev/null); do
        # The server is the tmux process whose parent is init -- clients are
        # children of a shell. Read the ppid with ps rather than field 4 of
        # /proc/PID/stat, whose comm field contains a space here and shifts
        # every column after it.
        ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        [[ $ppid == 1 ]] || continue
        cut -d: -f3 "/proc/$p/cgroup" 2>/dev/null
        return 0
    done
    return 1
}

linger_on() { [[ $(loginctl show-user deck --property=Linger --value 2>/dev/null) == yes ]]; }

# Root for one command only. Mirrors lib/elevate.sh's TTY logic: over SSH there
# is no GUI for an askpass helper to draw on, and in an agent shell or Game
# Mode there is no TTY for sudo to prompt on. Neither method works everywhere.
enable_linger() {
    linger_on && return 0
    if [[ $EUID -eq 0 ]]; then
        loginctl enable-linger deck
    elif [[ -t 0 ]]; then
        log "enabling linger for deck (sudo will prompt)"
        sudo loginctl enable-linger deck
    else
        log "enabling linger for deck (askpass dialog on the TV)"
        SUDO_ASKPASS="${SUDO_ASKPASS:-/usr/bin/ksshaskpass}" sudo -A loginctl enable-linger deck
    fi
}

ensure_unit() {
    mkdir -p "$USER_UNIT_DIR"
    # A symlink, not a copy, so editing the unit in the repo is the same thing
    # as editing the installed one -- same reasoning as the bashrc snippets.
    if [[ -L "$UNIT_DEST" && $(readlink -f "$UNIT_DEST") == "$(readlink -f "$UNIT_SRC")" ]]; then
        return 0
    fi
    [[ -e "$UNIT_DEST" && ! -L "$UNIT_DEST" ]] && die "$UNIT_DEST exists and is not a symlink -- move it aside first"
    ln -sfn "$UNIT_SRC" "$UNIT_DEST"
    log "linked $UNIT_DEST -> $UNIT_SRC"
    usysctl daemon-reload
}

ensure_bashrc() {
    [[ -f "$BASHRC" ]] || { warn "$BASHRC does not exist -- skipping shell wrapper"; return 0; }
    if grep -qF "$BASHRC_MARKER" "$BASHRC"; then
        return 0
    fi
    printf '\n%s\n[[ -f %s ]] && . %s\n' \
        "$BASHRC_MARKER" "$BASHRC_SNIPPET" "$BASHRC_SNIPPET" >> "$BASHRC"
    log "added the tmux wrapper to $BASHRC"
}

do_install() {
    command -v tmux >/dev/null || die "tmux is not installed"
    ensure_unit
    ensure_bashrc
    enable_linger || warn "could not enable linger -- the server still survives while a Game Mode or Desktop session is logged in, which on this machine is always"

    # The point the installer cannot fix for you. Everything above is inert
    # while a session-scoped server is still running, because tmux clients
    # attach to whatever server already owns the socket.
    local cg
    if cg=$(server_cgroup); then
        if [[ $cg == *"/session-"*".scope" ]]; then
            warn "a tmux server is running in $cg -- still doomed"
            warn "run this from OUTSIDE tmux, when nothing important is in it:"
            warn "    tmux kill-server && tmux"
        else
            log "running server is in $cg -- already outside the session scope"
        fi
    else
        log "no tmux server running -- the next 'tmux' will start it correctly"
    fi
    log "done -- open a new shell first, so the wrapper is in scope"
}

do_status() {
    printf '%-24s %s\n' 'tmux:' "$(command -v tmux >/dev/null && tmux -V || echo 'NOT INSTALLED')"
    # -I/-N, not -h: `rg -h` is --help, which prints a screenful of usage into
    # the status report and looks like a parse of the config file.
    printf '%-24s %s\n' 'logind kill policy:' \
        "$(rg -INe '^KillUserProcesses' /etc/systemd/logind.conf.d/*.conf 2>/dev/null | tail -1 || true)"
    printf '%-24s %s\n' 'user unit:' \
        "$([[ -L "$UNIT_DEST" ]] && echo "linked -> $(readlink "$UNIT_DEST")" || echo 'NOT linked')"
    # is-active exits non-zero for every state except active, so the || arm
    # would fire on a perfectly normal "inactive" and print both.
    printf '%-24s %s\n' 'unit state:' "$(usysctl is-active "$UNIT" 2>/dev/null || true)"
    printf '%-24s %s\n' 'linger:' "$(linger_on && echo enabled || echo 'NOT enabled')"
    printf '%-24s %s\n' 'bashrc hook:' \
        "$([[ -f "$BASHRC" ]] && grep -qF "$BASHRC_MARKER" "$BASHRC" && echo hooked || echo 'NOT hooked')"

    local cg
    if cg=$(server_cgroup); then
        printf '%-24s %s\n' 'server cgroup:' "$cg"
        case "$cg" in
            *"/session-"*".scope") printf '%-24s %s\n' 'verdict:' 'SESSION-SCOPED -- dies on disconnect' ;;
            *user@1000.service*)   printf '%-24s %s\n' 'verdict:' 'survives disconnect' ;;
            *)                     printf '%-24s %s\n' 'verdict:' 'unrecognised cgroup, check by hand' ;;
        esac
    else
        printf '%-24s %s\n' 'server cgroup:' 'no server running'
    fi
    printf '%-24s %s\n' 'sessions:' "$(tmux ls 2>/dev/null | tr '\n' ';' || echo none)"
}

# Leaves the ~/.bashrc block alone, same as hardware/sleep: blind sed on
# someone's .bashrc is a bad trade, and the wrapper is harmless without the
# unit -- `systemctl --user start` on a missing unit just fails and falls
# through to plain tmux.
do_uninstall() {
    usysctl stop "$UNIT" 2>/dev/null || true
    if [[ -L "$UNIT_DEST" ]]; then
        rm -f "$UNIT_DEST"
        usysctl daemon-reload
        log "removed $UNIT_DEST"
    fi
    if linger_on; then
        if [[ $EUID -eq 0 ]]; then
            loginctl disable-linger deck && log "linger disabled"
        else
            warn "linger left enabled -- remove with: sudo loginctl disable-linger deck"
        fi
    fi
    warn "the '$BASHRC_MARKER' block in $BASHRC is left in place -- remove it by hand"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    -h|--help)    sed -n '2,20p' "$0" ;;
    *)            die "unknown option: $1" ;;
esac
