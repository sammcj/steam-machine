#!/usr/bin/env bash
# Run every subsystem's install.sh in one go. See ./README.md.
#
#   sudo ./install.sh            same as --boot
#   sudo ./install.sh --boot     restore anything a SteamOS update removed
#   sudo ./install.sh --status   report every subsystem's state, change nothing
#   ./install.sh --list          list the subsystems and what each supports
#
# Each subsystem already has a systemd unit running its own `install.sh --boot`
# at every boot, so a SteamOS A/B update repairs itself without this script.
# What this adds is doing it *now* and in one place, with the output in front of
# you -- which is what you want immediately after an update rather than
# rebooting and hoping.
#
# ORDER MATTERS: hardware/kernel goes first. It restores /usr/lib/modules for
# the FRL kernel from the cache tarball, and hardware/sensors and
# hardware/bluetooth install out-of-tree modules (it87, btusb_mt7902) that have
# to land in a module tree that already exists.
#
# A failing subsystem does NOT stop the others. After an OS update the most
# useful outcome is "fifteen of seventeen restored, here are the two that did
# not", not a run that aborts on the first problem and leaves the rest undone.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# hardware/kernel first, then everything else in a stable order. Listing the
# first entry explicitly and filtering it out of the glob keeps this correct if
# a new subsystem is added -- no manually maintained list to fall behind.
subsystems() {
    local d
    echo "$REPO_DIR/hardware/kernel"
    for d in "$REPO_DIR"/hardware/*/ "$REPO_DIR"/system/*/; do
        d="${d%/}"
        [[ $d == "$REPO_DIR/hardware/kernel" ]] && continue
        [[ -f "$d/install.sh" ]] && echo "$d"
    done
}

# Not every subsystem has every mode -- system/btop has no --boot, for instance.
# Grepping the script is how that is detected, so a subsystem that gains a mode
# later is picked up with no change here.
supports() { rg -q -- "$2" "$1/install.sh" 2>/dev/null; }

do_list() {
    printf '%-28s %-7s %s\n' SUBSYSTEM --boot --status
    local d
    while read -r d; do
        printf '%-28s %-7s %s\n' "${d#$REPO_DIR/}" \
            "$(supports "$d" '--boot'   && echo yes || echo -)" \
            "$(supports "$d" '--status' && echo yes || echo -)"
    done < <(subsystems)
}

run_all() {
    local mode="$1"
    [[ $EUID -eq 0 ]] || die "must run as root: SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A $0 $mode"

    local d name ok=() skipped=() failed=()
    while read -r d; do
        name="${d#$REPO_DIR/}"
        if ! supports "$d" "$mode"; then
            skipped+=("$name")
            continue
        fi
        printf '\n\033[1m=== %s %s ===\033[0m\n' "$name" "$mode"
        if "$d/install.sh" "$mode"; then
            ok+=("$name")
        else
            failed+=("$name")
            warn "$name exited non-zero"
        fi
    done < <(subsystems)

    printf '\n\033[1m=== summary ===\033[0m\n'
    printf 'ok      : %s\n' "${#ok[@]}"
    [[ ${#skipped[@]} -gt 0 ]] && printf 'skipped : %s (no %s mode)\n' "${#skipped[@]}" "$mode"
    if [[ ${#failed[@]} -gt 0 ]]; then
        printf '\033[1;31mfailed  : %s\033[0m\n' "${failed[*]}"
        # Non-zero so this is usable from a script or a unit, and so a failure
        # after an OS update is not something you have to spot by reading.
        return 1
    fi
    printf 'failed  : 0\n'
    return 0
}

case "${1:---boot}" in
    --boot)   log "restoring every subsystem"; run_all --boot ;;
    --status) run_all --status ;;
    --list)   do_list ;;
    -h|--help) sed -n '2,20p' "$0" ;;
    *) die "usage: $0 [--boot | --status | --list]" ;;
esac
