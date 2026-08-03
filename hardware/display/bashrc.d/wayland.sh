# wayland -- restart the desktop session into Plasma Wayland, with a confirm.
#
# Sourced from ~/.bashrc by hardware/display/install.sh. Edits here take effect
# in the next shell; nothing needs reinstalling.
#
#   wayland          confirm, then switch this session to Plasma Wayland
#   wayland -y       skip the confirmation
#   wayland status   show the current session type and why it matters
#
# Why this exists: Steam's Power -> Switch to Desktop always lands on **X11**.
# `steamwebhelper` shells out to `steamos-session-select %s` with the legacy
# `plasma` alias, and /usr/bin/steamos-session-select hardcodes that case to
# `plasmax11.desktop`, bypassing the configured default-desktop-session
# (`plasma.desktop`, i.e. Wayland) entirely. SteamOS 3.8 made Wayland the
# intended Desktop Mode default, so this is a legacy-alias bug, not a setting --
# see ValveSoftware/SteamOS issue #2081, and ../README.md.
#
# It matters because HDR, Wide Colour Gamut, ICC profiles and colour management
# are all KWin **Wayland-only**. On X11 they report `incapable`, KDE hides the
# controls, and wide-gamut content goes unmanaged to the OLED -- which is the
# badly over-saturated look that prompted all this.
#
# This is per-session by design. It does NOT change boot behaviour: the machine
# still boots into Game Mode. `plasma-wayland-persistent` would also set
# default-login-mode to desktop, which is not wanted on a living-room console.

wayland() {
    local assume_yes=0

    case "${1:-}" in
        status|-s|--status)
            printf 'session type: %s\n' "${XDG_SESSION_TYPE:-unknown}"
            printf 'compositor:   %s\n' \
                "$(pgrep -a 'kwin_wayland|kwin_x11' 2>/dev/null | awk '{print $2}' | head -1)"
            printf 'default desktop session: %s\n' \
                "$(steamosctl get-default-desktop-session 2>/dev/null)"
            if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
                echo "-> already on Wayland; HDR and colour management available"
            else
                echo "-> on X11: no HDR, no colour management, over-saturated colour"
                echo "   run 'wayland' to switch"
            fi
            return 0
            ;;
        -y|--yes)
            assume_yes=1
            ;;
        -h|--help|help)
            echo "usage: wayland [-y] | wayland status"
            echo "  restarts the desktop session into Plasma Wayland"
            return 0
            ;;
        "") ;;
        *)
            echo "wayland: unknown argument '$1' (try: wayland --help)" >&2
            return 1
            ;;
    esac

    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        echo "wayland: already on a Wayland session -- nothing to do"
        return 0
    fi

    if ! command -v steamos-session-select >/dev/null 2>&1; then
        echo "wayland: steamos-session-select not found" >&2
        return 1
    fi

    if [[ $assume_yes -eq 0 ]]; then
        echo "This restarts the desktop session into Plasma Wayland."
        echo "All open windows will be closed -- save your work first."
        echo
        local reply
        read -r -p "Switch to Wayland now? [y/N] " reply
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "wayland: cancelled"; return 1 ;;
        esac
    fi

    echo "wayland: switching..."
    # setsid + nohup: the switch tears down this very session, and we do not
    # want the command killed partway through by the shell it is running in.
    setsid --fork nohup steamos-session-select plasma-wayland \
        >/dev/null 2>&1 </dev/null
}
