#!/usr/bin/env bash
# Interactive shell setup for this machine -- aliases and PATH/env exports.
#
#   ./install.sh              wire bashrc.d/*.sh into ~/.bashrc
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall  remove the hook lines from ~/.bashrc
#
# Needs no root: it only appends to a file the `deck` user owns.
#
# Persistence is trivial here and worth stating explicitly, because it is the
# exception in this repo rather than the rule. Nothing lands in /etc or /usr,
# so there is no atomic-update keep entry and no --boot self-heal: ~/.bashrc
# and the repo both live on /home, which is its own partition that a SteamOS
# A/B update does not touch.
#
# The snippets are *sourced from the repo* rather than copied into ~/.bashrc,
# so editing bashrc.d/aliases.sh takes effect in the next shell with nothing to
# reinstall. That is the same pattern as hardware/{sleep,display,coolercontrol},
# which each own a bashrc.d snippet of their own; this subsystem is only for
# the general-purpose ones that belong to no particular piece of hardware.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so the install/uninstall round trip can be exercised against a
# throwaway copy rather than the real thing.
BASHRC="${STEAM_MACHINE_BASHRC:-/home/deck/.bashrc}"

# marker|snippet, in source order. env before aliases, so PATH is set up before
# anything that might want to look a command up -- not that anything currently
# does, but the reverse order has no upside.
SNIPPETS=(
    "# steam-machine: shell environment|$REPO_DIR/bashrc.d/env.sh"
    "# steam-machine: shell aliases|$REPO_DIR/bashrc.d/aliases.sh"
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

do_install() {
    [[ -f "$BASHRC" ]] || die "$BASHRC does not exist"
    local entry marker snippet added=0
    for entry in "${SNIPPETS[@]}"; do
        marker="${entry%%|*}"
        snippet="${entry##*|}"
        [[ -f "$snippet" ]] || die "missing snippet: $snippet"
        if grep -qF "$marker" "$BASHRC"; then
            continue
        fi
        printf '\n%s\n[[ -f %s ]] && . %s\n' "$marker" "$snippet" "$snippet" >> "$BASHRC"
        log "added '$marker' to $BASHRC"
        added=1
    done
    [[ $added -eq 0 ]] && log "already wired into $BASHRC -- nothing to do"
    # Sourcing here would only affect this subshell, so say it rather than fake it.
    log "done -- open a new shell, or: . $BASHRC"
}

do_status() {
    local entry marker snippet
    printf 'bashrc:   %s\n' "$([[ -f "$BASHRC" ]] && echo "$BASHRC" || echo 'ABSENT')"
    for entry in "${SNIPPETS[@]}"; do
        marker="${entry%%|*}"
        snippet="${entry##*|}"
        printf '%-24s %s / %s\n' "${marker#\# steam-machine: }:" \
            "$([[ -f "$BASHRC" ]] && grep -qF "$marker" "$BASHRC" && echo 'hooked' || echo 'NOT hooked')" \
            "$([[ -f "$snippet" ]] && echo 'snippet present' || echo 'SNIPPET MISSING')"
    done
    echo
    # More than "is the line in the file": actually source the snippets in a
    # subshell, which catches a syntax error that would otherwise only show up
    # as a broken login shell. This process is not interactive, so the aliases
    # are not in scope here -- expand_aliases is what makes them visible.
    for entry in "${SNIPPETS[@]}"; do
        snippet="${entry##*|}"
        [[ -f "$snippet" ]] || continue
        printf '%-24s %s\n' "$(basename "$snippet"):" \
            "$(bash -c "shopt -s expand_aliases; . '$snippet' >/dev/null 2>&1 || exit 1;
                        printf '%s aliases, %s functions' \
                          \"\$(alias | wc -l)\" \"\$(declare -F | wc -l)\"" \
               2>/dev/null || echo 'FAILED TO SOURCE')"
    done
    printf '%-24s %s\n' "PATH:" "$PATH"
}

# Removes only the exact two-line block this installer writes. Anything that
# has been hand-edited since is left alone and reported, because blind sed on
# someone's .bashrc is a bad trade.
do_uninstall() {
    [[ -f "$BASHRC" ]] || die "$BASHRC does not exist"
    local backup="$BASHRC.steam-machine-shell.bak"
    cp -a "$BASHRC" "$backup"
    local entry marker snippet removed=0
    for entry in "${SNIPPETS[@]}"; do
        marker="${entry%%|*}"
        snippet="${entry##*|}"
        grep -qF "$marker" "$BASHRC" || continue
        local expected="[[ -f $snippet ]] && . $snippet"
        if awk -v m="$marker" -v e="$expected" '
            $0 == m { getline nxt; if (nxt != e) { bad = 1 } ; next }
            END { exit bad ? 1 : 0 }' "$BASHRC"; then
            awk -v m="$marker" '$0 == m { getline; next } { print }' "$BASHRC" > "$BASHRC.tmp"
            mv "$BASHRC.tmp" "$BASHRC"
            log "removed '$marker'"
            removed=1
        else
            warn "'$marker' block was edited by hand -- left in place, remove it yourself"
        fi
    done
    if [[ $removed -eq 1 ]]; then
        log "backup at $backup"
    else
        rm -f "$backup"
        log "nothing removed"
    fi
}

case "${1:-}" in
    ""|--install) do_install ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *)            die "unknown option: $1" ;;
esac
