# keepawake -- hold an explicit sleep inhibitor from a remote shell.
#
# Sourced from ~/.bashrc by hardware/sleep/install.sh. Edits here take effect in
# the next shell; nothing needs reinstalling.
#
#   keepawake            hold for 2h (the default)
#   keepawake 4h         hold for 4h -- any systemd time span: 30m, 90min, 1h30m
#   keepawake forever    hold with no timeout
#   keepawake off        release now
#   keepawake status     show what is holding sleep open
#
# This is the manual override. It is NOT needed just because you are SSH'd in --
# steam-machine-keepawake.service already holds the machine awake for as long as
# any SSH session exists, plus two hours after the last one ends. Reach for this
# when you want a hold that outlives your session: a long build, a big download,
# something you want to come back to.
#
# Why a transient systemd unit rather than `systemd-inhibit ... &`:
# /etc/systemd/logind.conf.d/killuserprocesses.conf sets KillUserProcesses=True,
# so every process in the session scope is killed when you log out -- a
# backgrounded inhibitor would die with the SSH connection, which is precisely
# the case this exists to cover. `systemd-run --user` parks it in the user
# manager instead, outside the session scope, where it survives logout.
# `loginctl enable-linger` is not needed: sddm autologins deck into the Deck UI
# with Relogin=true, so the user manager is always running.
#
# Requires /etc/polkit-1/rules.d/60-steam-machine-inhibit.rules -- without it
# logind demands an interactive password that a remote shell cannot supply.

keepawake() {
    local unit="keepawake.service"
    local dur="${1:-2h}"
    local host="${HOSTNAME:-$(uname -n)}"

    case "$dur" in
        off|stop|release)
            if systemctl --user is-active --quiet "$unit"; then
                systemctl --user stop "$unit"
                echo "keepawake: released"
            else
                echo "keepawake: nothing to release"
            fi
            return 0
            ;;
        status|-s|--status)
            if systemctl --user is-active --quiet "$unit"; then
                echo "keepawake: HOLDING (manual)"
                printf '  since:  %s\n' \
                    "$(systemctl --user show "$unit" -p ActiveEnterTimestamp --value)"
                printf '  expires after: %s\n' \
                    "$(systemctl --user show "$unit" -p RuntimeMaxUSec --value)"
            else
                echo "keepawake: no manual hold"
            fi
            echo
            echo "all sleep inhibitors currently registered:"
            # Header plus every lock that covers sleep. The automatic daemon's
            # lock shows up here too, as who=steam-machine-keepawake.
            systemd-inhibit --list 2>/dev/null | awk 'NR==1 || /sleep/'
            return 0
            ;;
        -h|--help|help)
            echo "usage: keepawake [DURATION|forever|off|status]"
            echo "  DURATION is a systemd time span (2h, 30m, 90min, 1h30m); default 2h"
            return 0
            ;;
    esac

    # RuntimeMaxSec=infinity is how systemd spells "no timeout".
    [[ "$dur" == "forever" ]] && dur="infinity"

    # Replace any existing hold rather than erroring on a duplicate unit name.
    systemctl --user stop "$unit" 2>/dev/null

    if ! systemd-run --user --quiet --collect --unit="$unit" \
        --description="keepawake: manual sleep inhibitor (${dur})" \
        --property=RuntimeMaxSec="$dur" \
        systemd-inhibit --what=sleep:idle --mode=block \
            --who="keepawake (${USER}@${host})" \
            --why="manual hold for ${dur}" \
            -- sleep infinity
    then
        echo "keepawake: could not start the transient unit (bad duration '${dur}'?)" >&2
        return 1
    fi

    # systemd-run exits as soon as the transient unit is queued, and reports
    # success even when the command it started dies immediately -- verified:
    # `systemd-run --user ... /bin/false` returns 0. So its exit status says
    # nothing about whether the lock was taken. Without a polkit rule
    # systemd-inhibit exits at once with "Failed to inhibit: Interactive
    # authentication required", and trusting systemd-run would cheerfully
    # report "holding for 2h" while nothing at all was held.
    #
    # Registering the lock also is not instant (~0.3s observed), so a check
    # against `systemd-inhibit --list` immediately after starting finds
    # nothing. Settle, then confirm the unit is still running.
    sleep 0.5
    if systemctl --user is-active --quiet "$unit"; then
        echo "keepawake: holding for ${dur} -- release early with 'keepawake off'"
        return 0
    fi

    # --collect has already reaped the failed unit, so `systemctl status` has
    # nothing left to show; the journal outlives it.
    echo "keepawake: FAILED to take the inhibitor" >&2
    journalctl --user -u "$unit" -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/  /' >&2
    echo "  check the polkit rule:" >&2
    echo "    sudo ~/git/steam-machine/hardware/sleep/install.sh --status" >&2
    return 1
}
