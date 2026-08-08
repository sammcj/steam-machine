#!/usr/bin/env bash
# Keep PortProton's default wine version pointed at the newest installed
# GE-Proton build.
#
#   ./install.sh              install the user units and set the default now
#   ./install.sh --update     set the default to the newest GE-Proton in dist
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall  remove the units, leave user.conf alone
#
# WHY THIS EXISTS
#
# PortProton's shipped default is PROTON_LG (data/scripts/var:48), which resolves
# to whatever PW_PROTON_LG_VER names -- a Valve Proton build, not GE. Overriding
# it means setting PW_WINE_USE, and there are only two places to do that:
#
#   data/scripts/var       shipped by PortProton, rewritten on every PortProton
#                          update. Editing it is pointless.
#   data/user.conf         user-owned, sourced after var (start.sh:208), never
#                          touched by an update. This is the one.
#
# Downloading a new GE-Proton does NOT change PW_WINE_USE -- PortProton only
# fetches the build, so user.conf keeps naming the old one until something
# rewrites it. That something is this script, fired by a systemd *user* path
# unit watching the dist directory.
#
# NOTHING HERE TOUCHES /etc OR /usr, so there is no --boot mode and no
# atomic-update keep entry: the script, the units (~/.config/systemd/user) and
# user.conf all live in /home and survive a SteamOS A/B update untouched. Do not
# run it with sudo -- the units are per-user and must be owned by deck.
#
# SCOPE: this sets the default for games added from now on. A game that already
# has a .ppdb file carries its own PW_WINE_USE, sourced after user.conf
# (functions_helper:2476), and keeps whatever it was created with. That is
# deliberate -- a game that works on the build it was tested against should not
# be silently moved to a new one. Change those in PortProton's per-game settings.
#
# PINNING: put `# pinned` at the end of the PW_WINE_USE line in user.conf and
# --update leaves it alone. Use that when a newer GE-Proton regresses something.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PORTPROTON_DIR="${PORTPROTON_DIR:-/home/deck/PortProton}"
DIST_DIR="$PORTPROTON_DIR/data/dist"
USER_CONF="$PORTPROTON_DIR/data/user.conf"

UNIT_DIR="/home/deck/.config/systemd/user"
PATH_UNIT="portproton-default-wine.path"
SVC_UNIT="portproton-default-wine.service"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

no_root() {
    [[ $EUID -ne 0 ]] || die "run as deck, not root -- these are per-user systemd units"
}

# --status is the one mode the top-level ./install.sh runs under sudo, and
# `systemctl --user` needs deck's session bus, which sudo does not carry.
as_deck() {
    local uid; uid="$(id -u deck)"
    if [[ $EUID -eq 0 ]]; then
        [[ -S "/run/user/$uid/bus" ]] || return 1
        runuser -u deck -- env \
            XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            "$@"
    else
        "$@"
    fi
}

# --- picking a version --------------------------------------------------------

# Newest GE-Proton in dist, by version sort. Empty output + non-zero if none.
#
# `proton` and `files/bin/wineserver` are the completeness check. The path unit
# fires the moment the directory appears, which is the *start* of extraction,
# not the end -- without this a half-extracted tree would win the sort and get
# written to user.conf as the default.
#
# nocaseglob because PortProton's own downloader writes GE-PROTON11-3 while
# ProtonUp-Qt writes GE-Proton11-3 into the same directory. Either is valid;
# PW_WINE_USE has to match the real directory name, so it comes from basename.
newest_ge() {
    local d name found=()
    shopt -s nocaseglob nullglob
    for d in "$DIST_DIR"/GE-PROTON*/; do
        d="${d%/}"
        [[ -f "$d/proton" && -f "$d/files/bin/wineserver" ]] || continue
        found+=("$(basename "$d")")
    done
    shopt -u nocaseglob nullglob
    [[ ${#found[@]} -gt 0 ]] || return 1
    printf '%s\n' "${found[@]}" | sort -V | tail -n1
}

# Block until nothing under $1 has changed for 10 seconds, up to ~2 minutes.
# Extracting a GE-Proton tarball takes a few seconds; a slow disk or a download
# that is still finishing takes longer. Returns non-zero if it never settles,
# in which case --update does nothing and the next path trigger retries.
settle() {
    local d="$1" i
    for ((i = 0; i < 24; i++)); do
        find "$d" -newermt '-10 seconds' -print -quit 2>/dev/null | grep -q . || return 0
        sleep 5
    done
    return 1
}

current_setting() {
    [[ -f "$USER_CONF" ]] || return 1
    sed -n 's/^export PW_WINE_USE="\([^"]*\)".*/\1/p' "$USER_CONF" | tail -n1
}

is_pinned() {
    [[ -f "$USER_CONF" ]] && grep -qE '^export PW_WINE_USE=.*#[[:space:]]*pinned' "$USER_CONF"
}

# --- the update ---------------------------------------------------------------

do_update() {
    no_root
    [[ -d "$DIST_DIR" ]] || die "no PortProton dist directory at $DIST_DIR"

    local newest current
    newest="$(newest_ge)" || die "no complete GE-Proton build found in $DIST_DIR"

    if is_pinned; then
        log "PW_WINE_USE is pinned to $(current_setting) -- leaving it alone (newest is $newest)"
        return 0
    fi

    settle "$DIST_DIR/$newest" || { warn "$newest still being written -- skipping this run"; return 0; }

    current="$(current_setting || true)"
    if [[ "$current" == "$newest" ]]; then
        log "already set to $newest"
        return 0
    fi

    # user.conf is a sourced bash file PortProton also edits from its own GUI
    # (functions_helper:3128), so keep to its format exactly: one `export K="V"`
    # per line. Replace in place if the key is there, append if not.
    if [[ ! -f "$USER_CONF" ]]; then
        printf '#!/usr/bin/env bash\n# User overides db and var settings...\n' > "$USER_CONF"
    fi
    if grep -qE '^export PW_WINE_USE=' "$USER_CONF"; then
        sed -i "s|^export PW_WINE_USE=.*|export PW_WINE_USE=\"$newest\"|" "$USER_CONF"
    else
        printf 'export PW_WINE_USE="%s"\n' "$newest" >> "$USER_CONF"
    fi

    log "default wine: ${current:-<unset>} -> $newest"
}

# --- install / uninstall ------------------------------------------------------

do_install() {
    no_root

    log "installing user units -> $UNIT_DIR"
    install -Dm644 "$REPO_DIR/systemd/$PATH_UNIT" "$UNIT_DIR/$PATH_UNIT"
    install -Dm644 "$REPO_DIR/systemd/$SVC_UNIT"  "$UNIT_DIR/$SVC_UNIT"

    systemctl --user daemon-reload || warn "user daemon-reload failed"
    # Both, and this is not redundant: the .path catches a build arriving while
    # you are logged in, the .service catches one that arrived while you were
    # not (a Flatpak update, another session, an offline install).
    systemctl --user enable --now "$PATH_UNIT" >/dev/null 2>&1 || warn "could not enable $PATH_UNIT"
    systemctl --user enable "$SVC_UNIT" >/dev/null 2>&1 || warn "could not enable $SVC_UNIT"

    log "applying now"
    do_update

    echo
    do_status
}

do_uninstall() {
    no_root
    systemctl --user disable --now "$PATH_UNIT" >/dev/null 2>&1 || true
    systemctl --user disable "$SVC_UNIT" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$PATH_UNIT" "$UNIT_DIR/$SVC_UNIT"
    systemctl --user daemon-reload || true
    log "units removed -- PW_WINE_USE in user.conf left as-is"
}

# `is-enabled` prints "not-found" and exits non-zero for a missing unit, so
# neither the output nor the exit status alone reads well -- fold both here.
unit_state() {
    local st
    st="$(as_deck systemctl --user is-enabled "$1" 2>/dev/null || true)"
    [[ -n $st && $st != "not-found" ]] && echo "$st" || echo "not installed"
}

do_status() {
    local newest current
    current="$(current_setting || true)"
    newest="$(newest_ge || true)"

    echo -n "user.conf:           "
    [[ -f "$USER_CONF" ]] && echo "$USER_CONF" || echo "MISSING"
    echo -n "PW_WINE_USE:         "
    echo "${current:-<unset> (PortProton default: PROTON_LG)}$(is_pinned && echo '  [pinned]')"
    echo -n "newest GE in dist:   "
    echo "${newest:-none}"
    echo -n "in sync:             "
    if [[ -z "$newest" ]]; then echo "n/a"
    elif [[ "$current" == "$newest" ]]; then echo "yes"
    elif is_pinned; then echo "no -- pinned on purpose"
    else echo "NO -- run $0 --update"; fi
    echo -n "path unit:           "
    unit_state "$PATH_UNIT"
    echo -n "service unit:        "
    unit_state "$SVC_UNIT"

    echo
    echo "installed builds in $DIST_DIR:"
    ls -1 "$DIST_DIR" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --update)     do_update ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
