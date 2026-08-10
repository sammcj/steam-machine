# Shared self-elevation for this repo's scripts. Source it, do not execute it.
#
#   source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../lib/elevate.sh"
#
# or, depth-independently, with the snippet at the bottom of this file.
#
# Provides:
#   elevate [args...]   re-run the calling script under sudo; returns if it could not
#   need_root [args...] elevate, then die if still not root  (drop-in for the
#                       one-line need_root each install.sh used to define)
#
# ---------------------------------------------------------------------------
# WHY THE PROMPT METHOD IS CHOSEN AT RUNTIME
#
# This machine has two shells with opposite requirements, and picking wrong is
# the usual reason "just run it with sudo" fails here:
#
#   - A TTY (interactive terminal, INCLUDING SSH) -> plain `sudo`, prompting in
#     the terminal. Over SSH there is no GUI at all, so an askpass helper cannot
#     draw and `sudo -A` dies with a bare "a password is required".
#   - No TTY (Game Mode, an agent shell, a systemd unit) -> `sudo -A` with
#     ksshaskpass, which pops a dialog on the TV. That needs the Desktop session
#     and the TV awake.
#
# Neither works everywhere, so elevation is BEST EFFORT: if it fails, elevate
# returns and the caller decides whether root was essential. Read-only reporting
# scripts carry on with a degraded report; installers call need_root and die.
# ---------------------------------------------------------------------------

# Guard against a re-exec loop if sudo ever yields a non-root shell.
_ELEVATE_GUARD=${_ELEVATE_GUARD:-}

elevate() {
    [[ $EUID -eq 0 ]] && return 0
    [[ -n $_ELEVATE_GUARD ]] && return 1
    [[ ${NO_SUDO:-0} -eq 1 ]] && return 1
    command -v sudo >/dev/null || return 1

    # ${BASH_SOURCE[-1]} is the outermost script -- the one the user ran --
    # rather than this library.
    local self; self=$(readlink -f "${BASH_SOURCE[-1]}") || return 1
    [[ -r $self ]] || return 1

    local rc
    if [[ -t 0 ]]; then
        printf '\033[1;33m==> re-running under sudo (Ctrl-C to skip)\033[0m\n' >&2
        _ELEVATE_GUARD=1 sudo -E -- "$self" "$@"; rc=$?
    else
        local askpass=${SUDO_ASKPASS:-/usr/bin/ksshaskpass}
        [[ -x $askpass ]] || return 1
        _ELEVATE_GUARD=1 SUDO_ASKPASS=$askpass sudo -AE -- "$self" "$@"; rc=$?
    fi

    # sudo returns 1 both for "authentication failed" and for "the script itself
    # failed", so only a clean run counts as handled. Anything else falls back
    # to the caller, which would otherwise hide a real failure behind a retry.
    [[ $rc -eq 0 ]] && exit 0
    return 1
}

# Replaces the one-line need_root each script used to define. Elevates first,
# and only dies if that could not be done -- so an install run from an SSH
# session now prompts in the terminal instead of failing with instructions.
#
# Note: elevation re-runs the script from the top, so anything printed before
# the need_root call is printed twice. Every caller in this repo checks root
# early, which keeps that to a line or two.
need_root() {
    # `|| true` is load-bearing: every install.sh runs under `set -e`, so a bare
    # `elevate "$@"` returning 1 (elevation declined or unavailable) would abort
    # the script right here, with sudo's own error as the only output and the
    # explanation below never reached.
    elevate "$@" || true
    [[ $EUID -eq 0 ]] && return 0
    # The hint deliberately does not echo "$@": need_root is often called with
    # no arguments from deep inside a mode handler, so reconstructing the
    # original command line from here produces a command that does the wrong
    # thing (e.g. dropping --cache).
    local hint="must run as root, and could not elevate automatically -- run it again with sudo from a terminal"
    command -v die >/dev/null 2>&1 && die "$hint"
    printf '\033[1;31m%s\033[0m\n' "$hint" >&2
    exit 1
}

# --- depth-independent sourcing snippet ---------------------------------------
# Scripts sit at varying depths (./install.sh, hardware/x/install.sh,
# hardware/x/bin/y.sh), so hardcoding ../../ is fragile. Walk up to the repo
# root instead:
#
#   _lib() {
#       local d; d=$(readlink -f "${BASH_SOURCE[0]}"); d=${d%/*}
#       while [[ $d != / ]]; do
#           [[ -r $d/lib/elevate.sh ]] && { printf '%s\n' "$d/lib/elevate.sh"; return 0; }
#           d=${d%/*}
#       done
#       return 1
#   }
#   _l=$(_lib) && source "$_l"
