# usb-reset -- recover a broken USB controller without rebooting.
#
# Sourced from ~/.bashrc by hardware/usb/install.sh. Edits here take effect in
# the next shell; nothing needs reinstalling.
#
#   usb-reset              reset every xHCI controller
#   usb-reset status       report controller state (no root needed)
#   usb-reset broken       reset only controllers that are actually broken
#   usb-reset watchdog     what the watchdog has been doing
#
# Anything starting with `-` is passed straight through, so
# `usb-reset --controller 0000:12:00.4 --dry-run` and `--force` work as well.
#
# When to reach for it: mouse, keyboard or headset have dropped off and are not
# coming back. `usb-reset status` says whether a controller is actually broken;
# `usb-reset broken` fixes it if one is. The watchdog service should get there
# first -- this is for when it has given up, or is not running.
usb-reset() {
    local script="/home/deck/git/steam-machine/hardware/usb/bin/usb-reset.sh"
    [[ -x "$script" ]] || { echo "usb-reset: $script not found" >&2; return 1; }

    case "${1:-}" in
        # Bare words rather than flags, because this is the thing you type at
        # 11pm when the mouse has stopped working. The script's own flags stay
        # available for scripting and for the watchdog.
        status)   shift; "$script" --status "$@" ;;
        broken)   shift; "$script" --broken "$@" ;;
        watchdog) shift; journalctl -u steam-machine-usb-watchdog.service \
                      --no-pager -n "${1:-40}" ;;
        help|-h|--help) "$script" --help ;;
        # The script self-elevates via lib/elevate.sh, which picks the right
        # prompt method for the shell it is in: a terminal prompt on a TTY
        # (including SSH), the graphical askpass in Game Mode.
        *)        "$script" "$@" ;;
    esac
}
