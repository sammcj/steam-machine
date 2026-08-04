# coolercontrol -- turn the monitoring daemon on for a measurement session, off again after.
#
# Sourced from ~/.bashrc by hardware/coolercontrol/install.sh. Edits here take
# effect in the next shell; nothing needs reinstalling.
#
#   coolercontrol on       start now, and on every boot until turned off
#   coolercontrol off      stop now, and don't start on boot (the default state)
#   coolercontrol status   full state report (no root needed)
#   coolercontrol ui       print the URLs the web UI is on
#   coolercontrol logs     tail the daemon's journal
#
# The daemon is installed but left disabled: it is a root process polling hwmon
# and the Super I/O continuously, with a LAN-reachable read/write API, and it is
# only wanted while actually measuring something. The usual session is
#
#   coolercontrol on   ->   reboot into gaming mode   ->   measure   ->   coolercontrol off
#
# "on" persists across reboots on purpose -- the enable symlink lives in
# /etc/systemd/system/multi-user.target.wants/, which is on the SteamOS keep
# list, so it survives an A/B update as well. Nothing here uninstalls anything;
# on/off is only ever the systemd enablement.

# An interactive shell can take sudo's own prompt. TTY-less callers (Claude's
# shell, a cron job) cannot, and need the graphical askpass on the TV instead.
_coolercontrol_sudo() {
    if [[ -t 0 ]]; then
        sudo "$@"
    else
        SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A "$@"
    fi
}

coolercontrol() {
    local script="/home/deck/git/steam-machine/hardware/coolercontrol/install.sh"
    local unit="coolercontrold.service"

    [[ -x "$script" ]] || { echo "coolercontrol: $script not found" >&2; return 1; }

    case "${1:-status}" in
        on|start|enable)
            _coolercontrol_sudo "$script" --enable || return 1
            # --enable is `systemctl enable --now`, so ExecStartPre has already
            # re-asserted apply_on_boot = false by the time this prints.
            echo "coolercontrol: ON -- http://localhost:11987 (and from the LAN)"
            echo "  stays on across reboots until 'coolercontrol off'"
            ;;
        off|stop|disable)
            _coolercontrol_sudo "$script" --disable || return 1
            echo "coolercontrol: OFF -- nothing uninstalled, 'coolercontrol on' brings it back"
            ;;
        status|-s|--status|"")
            local enabled active
            enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
            active="$(systemctl is-active "$unit" 2>/dev/null || true)"
            if [[ "$active" == active ]]; then
                echo "coolercontrol: ON (boot: ${enabled:-unknown})"
            else
                echo "coolercontrol: OFF (boot: ${enabled:-unknown}) -- 'coolercontrol on' to enable"
            fi
            echo
            "$script" --status
            ;;
        ui|url)
            echo "http://localhost:11987"
            echo "http://${HOSTNAME:-$(uname -n)}:11987"
            ;;
        logs|log|journal)
            shift
            _coolercontrol_sudo journalctl -u "$unit" --no-pager -n "${1:-50}"
            ;;
        -h|--help|help)
            echo "usage: coolercontrol [on|off|status|ui|logs [N]]"
            echo "  default is status; on/off need root (askpass pops on the TV from a TTY-less shell)"
            ;;
        *)
            echo "coolercontrol: unknown command '$1' (try: on off status ui logs)" >&2
            return 1
            ;;
    esac
}
