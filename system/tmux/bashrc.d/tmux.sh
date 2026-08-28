# steam-machine: tmux -- keep the server out of the SSH login's session scope.
#
# SteamOS sets KillUserProcesses=True, so a tmux server started directly by an
# SSH shell dies with that connection (see ../README.md). This wrapper makes
# sure the server is started by steam-machine-tmux.service instead, which puts
# it under user@1000.service where a dropped connection cannot reach it.
#
# Only the FIRST tmux invocation after a reboot matters: once a server exists
# on the default socket, every later client attaches to it and inherits
# whichever cgroup that server was started in -- for better or worse. That is
# also why installing this is not enough on its own; an already-running,
# session-scoped server has to be killed once before the fix takes effect.

tmux() {
    # No server yet -> start it as a unit rather than as a child of this shell.
    # `has-session` with no -t is true if the server has any session at all.
    if [[ -z ${TMUX:-} ]] && ! command tmux has-session 2>/dev/null; then
        systemctl --user start steam-machine-tmux.service 2>/dev/null || true
    fi

    # Bare `tmux` on a machine that already has sessions means "put me back
    # where I was" far more often than it means "make me a new session" -- the
    # whole point of this subsystem is reconnecting from a phone. `tmux new`
    # still creates one explicitly.
    if [[ $# -eq 0 && -z ${TMUX:-} ]] && command tmux has-session 2>/dev/null; then
        command tmux attach
        return
    fi

    # Falls through to plain tmux if the unit failed to start, so a broken
    # service degrades to the old behaviour rather than leaving no tmux at all.
    command tmux "$@"
}
