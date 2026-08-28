#!/usr/bin/env bash
# Journal retention: keep a week of logs instead of SteamOS's ~two days.
#
#   ./install.sh              install the drop-in, keep entry and boot unit
#   ./install.sh --boot       boot-time path: restore anything a SteamOS update
#                             dropped from /etc, then apply it. Run by the unit
#   ./install.sh --status     report state and measured retention, change nothing
#   ./install.sh --uninstall  remove everything and go back to Valve's defaults
#
# Nothing lands in /usr, which SteamOS replaces wholesale on every A/B update.
# The drop-in goes in /etc (an overlay: survives reboots unconditionally,
# survives updates only via the atomic-update.conf.d entry) and everything else
# lives in this repo under /home.
#
# The journal itself is already persistent and already on a partition that
# survives an update -- /var/log is a bind onto nvme0n1p8 at
# /.steamos/offload/var/log, the same 1.9T filesystem as /home. Only the
# *retention policy* was the problem, so this subsystem is a single config file
# plus the machinery to stop an OS update from eating it.
#
# No reboot required: journald picks the settings up on restart, which --install
# and --boot both do.
set -euo pipefail

# Shared self-elevation (lib/elevate.sh): provides elevate() and need_root().
# Walks up to the repo root so this works at any directory depth.
_lib() {
    local d; d=$(readlink -f "${BASH_SOURCE[0]}"); d=${d%/*}
    while [[ $d != / ]]; do
        [[ -r $d/lib/elevate.sh ]] && { printf '%s\n' "$d/lib/elevate.sh"; return 0; }
        d=${d%/*}
    done
    return 1
}
_l=$(_lib) && source "$_l"


REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONF_SRC="$REPO_DIR/journald.conf.d/zz-steam-machine-journal.conf"
CONF_DEST="/etc/systemd/journald.conf.d/zz-steam-machine-journal.conf"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-journal.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-journal.conf"
UNIT_SRC="$REPO_DIR/systemd/steam-machine-journal.service"
UNIT_DEST="/etc/systemd/system/steam-machine-journal.service"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# need_root() comes from lib/elevate.sh -- it elevates before dying.

# --- /etc self-heal -----------------------------------------------------------
# Cheap and idempotent, so it is safe on the boot fast path, and it runs BEFORE
# any early exit. /etc is an overlayfs with its upper layer in /var, writable
# even when steamos-readonly is enabled, so this needs no rootfs unlock.
#
# Returns 1 when nothing had to be restored, so callers can skip the journald
# restart on the overwhelmingly common boot where everything is already in place.
ensure_etc_config() {
    local src dest changed=1
    for src in "$CONF_SRC" "$KEEP_SRC" "$UNIT_SRC"; do
        case "$src" in
            "$CONF_SRC") dest="$CONF_DEST" ;;
            "$KEEP_SRC") dest="$KEEP_DEST" ;;
            *)           dest="$UNIT_DEST" ;;
        esac
        if ! cmp -s "$src" "$dest"; then
            install -Dm644 "$src" "$dest"
            warn "restored $dest (was missing or modified)"
            changed=0
        fi
    done
    return $changed
}

# Make journald read the config.
#
# There is no reload verb -- journald parses journald.conf once at start -- so a
# restart is the only way to apply this without a reboot. That is why --boot
# calls this ONLY when ensure_etc_config() actually restored something, i.e. on
# the first boot after an A/B update and never otherwise. A restart is cheap and
# supported (the /run/systemd/journal sockets are socket-activated and outlive
# the daemon, so clients reconnect and nothing loses its stdout), but it can drop
# a handful of in-flight messages, and doing that on every single boot to fix a
# problem that occurs a few times a year is a bad trade.
apply_journald() {
    systemctl restart systemd-journald.service \
        || warn "could not restart systemd-journald -- settings apply at next boot"
}

# --- reporting ----------------------------------------------------------------

# The merged, effective value of one journald.conf setting, read back from
# systemd rather than from our file. This is the check that matters: the whole
# subsystem turns on a drop-in filename sorting last, and reading our own file
# back would confirm nothing about whether it actually won.
effective() {
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
        | grep -E "^${1}=" | tail -1 | cut -d= -f2- || true
}

# Which file the winning value came from. cat-config precedes each file's
# contents with a '# /abs/path' header, so the last header seen before the last
# match wins.
#
# The header pattern must be ANCHORED AT BOTH ENDS. A bare /^# \// matches any
# comment line that happens to start with a path, and this very subsystem
# contains two of them -- the drop-in's own commentary cites
# /usr/lib/systemd/journald.conf.d/persistent-store.conf at the start of a line,
# and journald.conf's stock preamble has '# /etc/ if the original file ...'.
# With the loose pattern every value after such a line was attributed to
# whatever path the prose mentioned, which made --status fire its "the drop-in
# is being overridden" warning against a perfectly good install. Observed
# 2026-08-18, immediately after the first real install.
#
# A genuine header is the whole line: '#', one space, a path, end of line.
effective_source() {
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
        | awk -v key="^${1}=" '/^# \/[^[:space:]]+$/{f=$2} $0 ~ key {last=f} END{print last}'
}

# --- top level ----------------------------------------------------------------
do_install() {
    need_root

    [[ -f "$CONF_SRC" ]] || die "missing $CONF_SRC"

    log "installing $CONF_DEST"
    install -Dm644 "$CONF_SRC" "$CONF_DEST"

    log "installing $KEEP_DEST (survives SteamOS A/B updates)"
    install -Dm644 "$KEEP_SRC" "$KEEP_DEST"

    log "installing $UNIT_DEST"
    install -Dm644 "$UNIT_SRC" "$UNIT_DEST"
    systemctl daemon-reload
    systemctl enable steam-machine-journal.service >/dev/null 2>&1 \
        || warn "could not enable steam-machine-journal.service"

    log "restarting systemd-journald to apply (no reboot needed)"
    apply_journald

    log "done"
    echo
    do_status
}

do_boot() {
    need_root --boot
    # Restart only when something was actually restored -- see apply_journald().
    if ensure_etc_config; then
        apply_journald
    fi
}

do_status() {
    echo -n "journald drop-in:          "
    if [[ ! -f "$CONF_DEST" ]]; then
        echo "NOT installed"
    elif cmp -s "$CONF_SRC" "$CONF_DEST"; then
        echo "installed (matches repo)"
    else
        echo "installed but DIFFERS from repo"
    fi

    echo -n "atomic-update keep entry:  "
    [[ -f "$KEEP_DEST" ]] && echo "installed" || echo "MISSING (config lost on next OS update)"

    echo -n "boot self-heal unit:       "
    systemctl is-enabled steam-machine-journal.service >/dev/null 2>&1 \
        && echo "enabled" || echo "NOT enabled"

    echo
    echo "effective config (merged -- this is the check that matters, since the"
    echo "whole subsystem rests on 'zz-' sorting after Valve's drop-ins):"
    local k v src
    for k in Storage MaxRetentionSec SystemMaxUse SystemMaxFileSize; do
        v="$(effective "$k")"
        src="$(effective_source "$k")"
        printf '  %-18s %-10s %s\n' "$k" "${v:-(unset)}" "${src:+from $src}"
    done

    # A value winning from anywhere other than our file means the drop-in lost
    # the sort, which is silent and looks exactly like success otherwise.
    if [[ -n "$(effective MaxRetentionSec)" && "$(effective_source MaxRetentionSec)" != "$CONF_DEST" ]]; then
        echo
        warn "MaxRetentionSec is coming from $(effective_source MaxRetentionSec), not $CONF_DEST"
        warn "  the drop-in is being overridden -- check the filename sort order"
    fi

    echo
    echo "journal on disk:"
    # Pull the size out of "Archived and active journals take up 46.1M in the
    # file system." -- the unit suffix is required in the pattern, otherwise the
    # sentence's closing full stop matches as a bare number and wins.
    printf '  %-18s %s\n' "usage" "$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGTP]' | head -1 || echo '?')"
    printf '  %-18s %s\n' "storage path" "$(findmnt -no SOURCE -T /var/log 2>/dev/null || echo '?')"

    # Measured retention, not configured retention. These differ whenever the
    # size cap binds before the time cap, and the measured figure is the one
    # that answers "will last night's logs still be here tomorrow evening".
    #
    # NOTE the asymmetry, which is easy to get wrong and fails silently as a
    # span of 0: `-n1` means "the last N entries", so it returns the NEWEST
    # entry regardless of --reverse. The oldest has to come from the head of the
    # unlimited stream, which journalctl emits oldest-first -- `head -1` closes
    # the pipe immediately, so this does not read all 46 MB.
    local oldest newest
    oldest="$(journalctl --no-pager -o short-iso 2>/dev/null | head -1 | cut -d' ' -f1 || true)"
    newest="$(journalctl --no-pager -o short-iso -n1 2>/dev/null | tail -1 | cut -d' ' -f1 || true)"
    printf '  %-18s %s\n' "oldest entry" "${oldest:-?}"
    printf '  %-18s %s\n' "newest entry" "${newest:-?}"
    if [[ -n "$oldest" && -n "$newest" ]]; then
        printf '  %-18s %s\n' "actual span" \
            "$(awk -v s=$(( $(date -d "$newest" +%s) - $(date -d "$oldest" +%s) )) \
                'BEGIN{printf "%.1f day(s)", s/86400}')"
    fi

    # `--list-boots` prints a header row, so a bare wc -l always overcounts by
    # one and reports 1 for an empty journal. Count rows carrying a boot ID.
    echo
    printf 'boots retained: %s\n' \
        "$(journalctl --list-boots --no-pager 2>/dev/null | grep -cE '[0-9a-f]{32}' || echo 0)"
}

do_uninstall() {
    need_root --uninstall
    systemctl disable --now steam-machine-journal.service >/dev/null 2>&1 || true
    rm -f "$CONF_DEST" "$KEEP_DEST" "$UNIT_DEST"
    systemctl daemon-reload

    # Deleting the drop-in only stops it being *read* at the next journald start.
    # Without this restart the machine would keep a week of logs while claiming
    # to be uninstalled -- and the excess is then vacuumed the moment journald
    # next restarts on its own, which looks like data loss out of nowhere.
    log "restarting systemd-journald -- SteamOS defaults (50M) apply immediately,"
    log "which will vacuum anything above that cap right now"
    apply_journald
    log "uninstalled"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --boot)       do_boot ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
