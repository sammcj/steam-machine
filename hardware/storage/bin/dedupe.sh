#!/usr/bin/env bash
# Out-of-band deduplication for the game library, via duperemove.
#
# SCOPE IS DELIBERATELY NARROW. Btrfs has no in-kernel dedupe, so this is a
# batch pass that hashes files and issues dedupe ioctls. On a Steam library the
# return is very uneven:
#
#   - Game assets: near zero. Titles ship precompressed, unique data. Deduping
#     them costs hours of I/O for nothing, AND splits large sequential extents,
#     which is exactly the fragmentation you do not want on the files that
#     determine level load times.
#   - Proton prefixes (compatdata): worthwhile. Every prefix is a near-identical
#     tree of Windows DLLs, ~0.5-1 GB each, one per game.
#   - Shader caches: worthwhile for the same reason, and fragmentation there is
#     harmless -- they are read in small random chunks anyway.
#
# So by default this runs over compatdata and shadercache only. `--all` widens
# it to the whole volume if you want to measure the difference yourself.
#
#   ./dedupe.sh            compatdata + shadercache (what the timer runs)
#   ./dedupe.sh --all      entire volume -- slow, and see the fragmentation note
#   ./dedupe.sh --dry-run  report what would be deduped, change nothing
set -euo pipefail

MOUNT_POINT="${GAMES_MOUNT:-/home/deck/SATA}"
HASHFILE="/home/deck/.cache/steam-machine-storage/duperemove.db"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

MODE="scoped"
case "${1:-}" in
    --all)     MODE="all" ;;
    --dry-run) MODE="dryrun" ;;
    "")        ;;
    *) die "unknown option: $1" ;;
esac

grep -q " $MOUNT_POINT btrfs " /proc/mounts || die "$MOUNT_POINT is not mounted"

# SteamOS A/B updates replace /usr, so duperemove disappears with it. Reinstall
# on demand rather than carrying a boot unit just for this -- the timer is
# monthly, so one pacman call a month is cheap.
ensure_duperemove() {
    command -v duperemove >/dev/null 2>&1 && return 0

    log "duperemove not present, installing"
    local keycount
    keycount="$(pacman-key --list-keys 2>/dev/null | grep -c '^pub' || true)"
    if [[ "${keycount:-0}" -eq 0 ]]; then
        pacman-key --init >/dev/null 2>&1 || true
        pacman-key --populate archlinux holo >/dev/null 2>&1 || true
    fi
    if command -v steamos-readonly >/dev/null 2>&1 \
       && [[ "$(steamos-readonly status 2>/dev/null)" == "enabled" ]]; then
        steamos-readonly disable
    fi
    # -Sy, never -Syu: a partial upgrade on SteamOS is how you break the boot.
    pacman -Sy --needed --noconfirm duperemove >/dev/null 2>&1 \
        || die "could not install duperemove (network down?)"
}

ensure_duperemove

TARGETS=()
if [[ "$MODE" == "all" ]]; then
    TARGETS=("$MOUNT_POINT")
else
    for d in "$MOUNT_POINT"/steamapps/compatdata "$MOUNT_POINT"/steamapps/shadercache; do
        [[ -d "$d" ]] && TARGETS+=("$d")
    done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    log "nothing to dedupe yet (no compatdata/shadercache -- install some games first)"
    exit 0
fi

mkdir -p "$(dirname "$HASHFILE")"

# -r          recurse
# -d          actually dedupe (without it, duperemove only reports)
# --hashfile  persist hashes so each run is incremental rather than a full rehash
# -b 128K     larger blocks than the 4K minimum: fewer, longer extents, which
#             keeps fragmentation down at a small cost in matches found
ARGS=(-r -b 128K --hashfile "$HASHFILE")
[[ "$MODE" != "dryrun" ]] && ARGS+=(-d)

log "duperemove over: ${TARGETS[*]}"
[[ "$MODE" == "dryrun" ]] && log "(dry run -- no changes)"

# Lowest possible priority: this must never compete with a running game.
ionice -c 3 nice -n 19 duperemove "${ARGS[@]}" "${TARGETS[@]}"

log "done"
