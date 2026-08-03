#!/usr/bin/env bash
# CoolerControl daemon + web UI, for logging this build's temps over time.
#
#   ./install.sh              download (verified), install, configure, start
#   ./install.sh --lan        as above, but bind the UI to the LAN, not just
#                             localhost  (see README -- this is unauthenticated
#                             read access and authenticated write access)
#   ./install.sh --boot       boot-time path (ExecStartPre): restore anything a
#                             SteamOS update dropped, and re-assert the
#                             monitoring-only settings before the daemon starts
#   ./install.sh --status     report current state and exit
#   ./install.sh --disable    stop now and don't start on boot (keeps everything
#                             installed and configured)
#   ./install.sh --enable     undo --disable
#   ./install.sh --uninstall  remove daemon, service and config
#
# Only the daemon is installed. Since v4 it embeds the whole web UI and serves
# it itself, so the separate desktop/Tauri app buys nothing on a machine whose
# display is a TV running Gamescope.
#
# Nothing lands in /usr, which SteamOS replaces wholesale on every A/B update.
# The binary is under /home and the daemon's state under /var, both separate
# partitions. /etc is an overlay: it survives reboots unconditionally but only
# an allowlisted subset survives an A/B update, hence the atomic-update.conf.d
# entry and the --boot self-heal.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION="4.3.1"
SHA256="982732cb744f2c93bde17b59d550771d98c26385d2238bd35b1494ef6682b484"
URL="https://gitlab.com/api/v4/projects/30707566/packages/generic/coolercontrol/${VERSION}/coolercontrold_${VERSION}"

CACHE_DIR="${CC_CACHE:-/home/deck/.cache/steam-machine-coolercontrol}"
INSTALL_DIR="/home/deck/.local/lib/coolercontrol"
BIN="$INSTALL_DIR/coolercontrold"
UNIT="/etc/systemd/system/coolercontrold.service"
CONFIG="/etc/coolercontrol/config.toml"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-coolercontrol.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-coolercontrol.conf"
SERVICE="coolercontrold.service"
PORT=11987

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A $0)"; }

# --- fetch --------------------------------------------------------------------
# Pinned by version *and* sha256. The binary is 37 MB, so it is cached under
# /home rather than committed; the checksum is what makes that reproducible.
fetch() {
    local cached="$CACHE_DIR/coolercontrold_$VERSION"
    if [[ -f "$cached" ]] && echo "$SHA256  $cached" | sha256sum -c --status; then
        log "using cached coolercontrold $VERSION"
    else
        log "downloading coolercontrold $VERSION"
        mkdir -p "$CACHE_DIR"
        curl -fL --retry 3 --retry-delay 5 -o "$cached.part" "$URL" \
            || die "download failed"
        echo "$SHA256  $cached.part" | sha256sum -c --status \
            || { rm -f "$cached.part"; die "checksum mismatch -- refusing to install"; }
        mv "$cached.part" "$cached"
    fi
    # Deliberately root-owned even though it sits under /home: systemd runs it
    # as root, and a root-executed binary should not be user-writable.
    install -Dm755 -o root -g root "$cached" "$BIN"
}

# --- config -------------------------------------------------------------------
# The daemon owns config.toml -- it rewrites it on every save and preserves
# comments while doing so. So rather than shipping a file, the daemon is run
# once to generate its own, and only the [settings] keys that matter here are
# then forced. Idempotent: re-running changes nothing once they are set.
generate_config() {
    [[ -f "$CONFIG" ]] && return 0
    log "generating initial config"
    mkdir -p /etc/coolercontrol
    # --config parses, and on a missing file creates, config.toml -- without
    # starting up or touching hardware. Falls back to a short supervised run.
    "$BIN" --config >/dev/null 2>&1 || true
    if [[ ! -f "$CONFIG" ]]; then
        warn "--config did not write one; starting the daemon briefly instead"
        timeout 15 "$BIN" >/dev/null 2>&1 || true
    fi
    [[ -f "$CONFIG" ]] || die "daemon did not create $CONFIG"
}

# Set key = value inside [settings], adding the key if the daemon's default
# config omitted it. Anything outside [settings] is untouched.
set_setting() {
    local key="$1" value="$2"
    python3 - "$CONFIG" "$key" "$value" <<'PY'
import re, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
# [ \t]* rather than \s*: \s eats newlines, so a greedy match would run past
# the section header and land the insertion point in the middle of the body.
header = re.compile(r'^\[settings\][ \t]*$', re.M)
m = header.search(text)
if not m:
    text = text.rstrip('\n') + '\n\n[settings]\n'
    m = header.search(text)
start = m.end()                       # just before the header's newline
nxt = re.search(r'^\[', text[start:], re.M)
end = start + (nxt.start() if nxt else len(text) - start)
body = text[start:end]
kv = re.compile(rf'^[ \t]*{re.escape(key)}[ \t]*=.*$', re.M)
found = kv.search(body)
if found:
    if found.group(0).strip() == f'{key} = {value}':
        sys.exit(0)                   # already set -- leave the file alone
    body = kv.sub(f'{key} = {value}', body, count=1)
else:
    body = f'\n{key} = {value}' + body
open(path, 'w').write(text[:start] + body + text[end:])
print(f'  set {key} = {value}')
PY
}

configure() {
    generate_config
    # Monitoring only. The board's fan curves stay under BIOS control -- see
    # hardware/sensors/README.md; nothing here should write pwmN_enable.
    set_setting apply_on_boot false
    # No liquidctl-supported hardware in this build (the AIO is a plain PWM
    # unit on an ITE header). Off avoids the Python dependency and the USB
    # probing that comes with it.
    set_setting liquidctl_integration false
    if [[ "${LAN:-0}" == 1 ]]; then
        set_setting ipv4_address '"0.0.0.0"'
        set_setting allow_unencrypted true
    fi
}

# Only an allowlisted subset of /etc carries into a new OS image, and
# /etc/coolercontrol is not on the default list -- hence the keep entry. See
# atomic-update.conf.d/steam-machine-coolercontrol.conf for why this one is a
# wildcard where the rest of this repo lists files individually.
ensure_keep_entry() {
    if ! cmp -s "$KEEP_SRC" "$KEEP_DEST"; then
        install -Dm644 "$KEEP_SRC" "$KEEP_DEST"
        log "installed atomic-update keep entry"
    fi
}

# --- install ------------------------------------------------------------------
do_install() {
    need_root
    command -v python3 >/dev/null || die "python3 required"
    fetch
    ensure_keep_entry
    install -Dm644 "$REPO_DIR/systemd/coolercontrold.service" "$UNIT"
    systemctl daemon-reload

    # The daemon owns config.toml and writes its in-memory state back over the
    # file when it shuts down. Editing it under a running daemon looks like it
    # worked and is then silently reverted by the next stop -- upstream's own
    # header says to stop the daemon before editing by hand. So: stop, edit,
    # start. (--boot needs no such care; it runs as ExecStartPre.)
    systemctl stop "$SERVICE" 2>/dev/null || true
    configure
    log "enabling $SERVICE"
    systemctl enable --now "$SERVICE"

    sleep 3
    systemctl is-active --quiet "$SERVICE" \
        || die "daemon failed to start -- journalctl -u $SERVICE"
    verify_no_pwm_writes
    log "done -- UI at http://localhost:$PORT"
}

# --- boot ---------------------------------------------------------------------
# Runs as the daemon's ExecStartPre, so it must be quick and must leave the
# system in a state where starting the daemon is safe.
#
# The binary (/home) and the daemon's state (/var) are on their own partitions
# and need no restoring. /etc/coolercontrol does: it is not on the default keep
# list, so an update predating the keep entry -- or a keep entry that went
# missing with it -- takes the whole config with it, `apply_on_boot = false`
# included. The daemon would then come back with the upstream default of true.
#
# Deliberately not `ExecStartPre=-`: if the monitoring-only settings cannot be
# guaranteed, not starting is the right outcome. This blocks temperature
# graphs, never boot.
do_boot() {
    need_root
    ensure_keep_entry
    [[ -f "$CONFIG" ]] || warn "$CONFIG was missing -- regenerating (UI customisations are lost)"
    configure
}

# The whole point of apply_on_boot = false. Loud if it ever stops holding.
verify_no_pwm_writes() {
    local f v bad=0
    for f in /sys/class/hwmon/hwmon*/pwm*_enable; do
        [[ -e "$f" ]] || continue
        v="$(cat "$f")"
        # 2 = automatic/BIOS control on it87. 1 would mean manual PWM.
        [[ "$v" == 2 ]] || { warn "$f = $v (expected 2 = BIOS control)"; bad=1; }
    done
    [[ $bad -eq 0 ]] && log "fan control still with the BIOS (all pwm*_enable = 2)"
}

# `systemctl is-enabled`/`is-active` print the state on stdout *and* exit
# non-zero for every state but enabled/active -- so a `|| echo` fallback prints
# both, and under `set -o pipefail` even a `| grep .` pipeline still inherits
# the non-zero status. Capture, then only substitute when there is no output.
svc_state() {
    local out
    out="$(systemctl "$1" "$SERVICE" 2>/dev/null)" || true
    printf '%s' "${out:-not installed}"
}

do_status() {
    printf 'binary:   %s\n' "$([[ -x "$BIN" ]] && "$BIN" --version 2>/dev/null || echo 'not installed')"
    printf 'unit:     %s\n' "$(svc_state is-enabled)"
    printf 'active:   %s\n' "$(svc_state is-active)"
    printf 'config:   %s\n' "$([[ -f "$CONFIG" ]] && echo "$CONFIG" || echo 'absent')"
    printf 'keep:     %s\n' "$(cmp -s "$KEEP_SRC" "$KEEP_DEST" && echo "$KEEP_DEST" \
        || echo 'MISSING or stale -- config will not survive an OS update')"
    if [[ -f "$CONFIG" ]]; then
        sed -n '/^\[settings\]/,/^\[/p' "$CONFIG" | grep -E '^(apply_on_boot|liquidctl_integration|ipv4_address|allow_unencrypted|poll_rate)' || true
    fi
    printf 'api:      %s\n' "$(curl -fsS --max-time 3 "http://localhost:$PORT/handshake" 2>/dev/null || echo 'unreachable')"
    printf 'listen:   %s\n' "$(ss -tln 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {printf "%s ", $4}' || true)"
    echo
    verify_no_pwm_writes
}

# --- on/off -------------------------------------------------------------------
# Nothing is removed -- the binary, config and keep entry all stay put, so --enable
# brings it back exactly as it was. The enable symlink lives under
# /etc/systemd/system/multi-user.target.wants/, which is on the default keep
# list, so "off" survives a SteamOS A/B update just as "on" does.
do_disable() {
    need_root
    systemctl disable --now "$SERVICE"
    log "stopped, and will not start on boot -- ./install.sh --enable to undo"
}

do_enable() {
    need_root
    systemctl enable --now "$SERVICE"
    log "started, and will start on boot"
}

do_uninstall() {
    need_root
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT" "$KEEP_DEST"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    log "removed daemon, unit and keep entry"
    log "left in place: $CONFIG, /var/lib/coolercontrol, $CACHE_DIR"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --lan)        LAN=1 do_install ;;
    --boot)       do_boot ;;
    --status)     do_status ;;
    --disable)        do_disable ;;
    --enable)         do_enable ;;
    --uninstall)  do_uninstall ;;
    *)            die "unknown option: $1" ;;
esac
