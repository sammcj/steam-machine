#!/usr/bin/env bash
# Display configuration for the LG C9 on the RX 9070 XT.
#
#   ./install.sh            install config (idempotent)
#   ./install.sh --status   report current state and exit
#   ./install.sh --boot     self-heal after a SteamOS update (systemd unit)
#   ./install.sh --seam     capture display state while the 4K120 seam is visible
#   ./install.sh --uninstall
#
# Installs:
#   /etc/modprobe.d/amdgpu-display.conf          amdgpu module options
#   /etc/atomic-update.conf.d/steam-machine-display.conf   keeps the above
#                                                across SteamOS A/B updates
#   /usr/local/bin/steamos-session-select        shim: makes Steam's "Switch to
#                                                Desktop" land on Wayland
#   /etc/systemd/system/steam-machine-display.service      reinstalls that shim
#                                                after an OS update
#
# The /etc files need no rootfs unlock: /etc is an overlayfs with its upper
# layer in /var/lib/overlays/etc/upper, writable even when steamos-readonly is
# enabled. The shim does -- /usr/local is on the rootfs subvolume, which an A/B
# update replaces wholesale, hence the boot unit.
#
# The modprobe.d part requires a reboot: amdgpu module parameters are read-only
# at runtime (/sys/module/amdgpu/parameters/* is mode 0444) and amdgpu cannot be
# reloaded while the display is up. The shim takes effect immediately.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODPROBE_SRC="$REPO_DIR/modprobe.d/amdgpu-display.conf"
MODPROBE_DEST="/etc/modprobe.d/amdgpu-display.conf"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-display.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-display.conf"

BASHRC="/home/deck/.bashrc"
BASHRC_SNIPPET="$REPO_DIR/bashrc.d/wayland.sh"
BASHRC_MARKER="# steam-machine: wayland session switch"

SHIM_SRC="$REPO_DIR/bin/steamos-session-select-shim"
SHIM_DEST="/usr/local/bin/steamos-session-select"
VALVE_BIN="/usr/bin/steamos-session-select"

UNIT_SRC="$REPO_DIR/systemd/steam-machine-display.service"
UNIT_NAME="steam-machine-display.service"
UNIT_DEST="/etc/systemd/system/$UNIT_NAME"

# --- TV re-detect ------------------------------------------------------------
# All of this existed because the CH7218 DP->HDMI converter was the DP sink: it
# held HPD asserted and answered EDID from cache whether the TV was on or off,
# so nothing on this side could tell that the TV had woken up. See ./README.md.
#
# That converter was removed on 2026-08-06 -- the TV is now on the GPU's native
# HDMI port, which has real hot-plug detect and re-detects by itself. The
# automatic triggers below therefore fire into a working link and achieve
# nothing except a visible one-second blank each time. Retired 2026-08-06.
#
# The hotkey daemon is kept: it costs nothing while idle and is the thing you
# reach for when the screen is already black.
REDETECT_UNITS_ENABLED=(
    steam-machine-display-hotkey.service
)
REDETECT_UNITS_TRIGGERED=()

# Actively removed, not merely left uninstalled -- they are enabled on this
# machine right now, and /etc/systemd/system is on the SteamOS keep list, so
# they would otherwise survive indefinitely. The unit files stay in the repo:
# if a future setup puts a converter back in the chain, they are the answer.
REDETECT_UNITS_RETIRED=(
    steam-machine-display-redetect-boot.service
    steam-machine-display-redetect-resume.service
    steam-machine-display-redetect.service
)
UDEV_SRC="$REPO_DIR/udev/99-steam-machine-display-redetect.rules"
UDEV_DEST="/etc/udev/rules.d/99-steam-machine-display-redetect.rules"
REDETECT_BIN="$REPO_DIR/bin/display-redetect"
HOTKEY_BIN="$REPO_DIR/bin/display-hotkey-daemon"

SWITCH_BIN="$REPO_DIR/bin/wayland-switch"
DESKTOP_SRC="$REPO_DIR/desktop/steam-machine-wayland.desktop.in"
DESKTOP_NAME="steam-machine-wayland.desktop"
# Both copies point at the same script in the repo: the Desktop icon for a
# double-click, the applications entry so it is findable from the launcher.
DESKTOP_DESTS=(
    "/home/deck/Desktop/$DESKTOP_NAME"
    "/home/deck/.local/share/applications/$DESKTOP_NAME"
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"; }

param() { cat "/sys/module/amdgpu/parameters/$1" 2>/dev/null || echo "?"; }

# --- SteamOS read-only rootfs -------------------------------------------------
# Only /usr/local/bin needs this; everything else this script writes is in /etc.
# Same helper as hardware/storage and system/rustdesk. The state is restored on
# the way out so a machine that was locked stays locked.
RO_WAS_ENABLED=0
unlock_rootfs() {
    if command -v steamos-readonly >/dev/null 2>&1 \
       && [[ "$(steamos-readonly status 2>/dev/null)" == "enabled" ]]; then
        RO_WAS_ENABLED=1
        log "unlocking read-only rootfs"
        steamos-readonly disable
    fi
}
relock_rootfs() {
    if [[ $RO_WAS_ENABLED -eq 1 ]] && command -v steamos-readonly >/dev/null 2>&1; then
        log "restoring read-only rootfs"
        steamos-readonly enable || warn "could not re-enable read-only rootfs"
    fi
}

# --- the session-select shim --------------------------------------------------
# Makes Steam's Power -> "Switch to Desktop" land on a Wayland Plasma session
# instead of X11, by shadowing Valve's script earlier on PATH. See
# bin/steamos-session-select-shim for the full reasoning.
#
# Deliberately compares content rather than mere existence: an A/B update
# deletes the file outright, but a half-written or edited copy is the case that
# would otherwise be reported as installed and working.
shim_ok() {
    [[ -x "$SHIM_DEST" ]] && cmp -s "$SHIM_SRC" "$SHIM_DEST"
}

ensure_shim() {
    [[ -f "$SHIM_SRC" ]] || die "missing $SHIM_SRC"
    # Valve's script is what the shim delegates to. If it is gone, installing a
    # shim in front of it would turn "no session switching" into "no session
    # switching, plus a confusing extra file".
    [[ -x "$VALVE_BIN" ]] || die "$VALVE_BIN is missing -- refusing to install a shim with nothing to delegate to"
    # Refuse to run a syntactically broken shim: this file sits between the user
    # and the only way back out of Desktop Mode from the couch.
    bash -n "$SHIM_SRC" || die "$SHIM_SRC does not parse -- refusing to install"

    if shim_ok; then
        return 0
    fi

    trap relock_rootfs EXIT
    unlock_rootfs
    log "installing $SHIM_DEST"
    install -Dm755 "$SHIM_SRC" "$SHIM_DEST"
    relock_rootfs
    RO_WAS_ENABLED=0
    trap - EXIT

    # Prove the mapping rather than assuming it. The shim's dry-run mode prints
    # what it would exec without touching the session.
    local out
    out="$(STEAM_MACHINE_SESSION_DRYRUN=1 "$SHIM_DEST" plasma 2>&1)" || true
    [[ "$out" == *"plasma-wayland"* ]] \
        || die "shim installed but does not rewrite 'plasma' -- got: $out"
    out="$(STEAM_MACHINE_SESSION_DRYRUN=1 "$SHIM_DEST" gamescope 2>&1)" || true
    [[ "$out" == *"$VALVE_BIN gamescope"* ]] \
        || die "shim installed but does not pass 'gamescope' through -- got: $out"
}

# The unit that puts the shim back after an A/B update wipes /usr/local.
ensure_unit() {
    [[ -f "$UNIT_SRC" ]] || die "missing $UNIT_SRC"
    if [[ ! -f "$UNIT_DEST" ]] || ! cmp -s "$UNIT_SRC" "$UNIT_DEST"; then
        log "installing $UNIT_DEST"
        install -Dm644 "$UNIT_SRC" "$UNIT_DEST"
        systemctl daemon-reload
    fi
    systemctl is-enabled --quiet "$UNIT_NAME" 2>/dev/null || systemctl enable "$UNIT_NAME"
}

# --- TV re-detect triggers ----------------------------------------------------
# Nothing here needs a rootfs unlock: the scripts run from the repo on /home,
# and everything installed lands in /etc. That is also why the units carry
# RequiresMountsFor=/home/deck.
#
# Content-compared rather than existence-checked, for the same reason as the
# shim: an A/B update deletes the udev rule outright, but a stale copy left by
# an older revision of this repo is the case that would otherwise report as
# installed and working while firing the wrong arguments.
# Reports whether any retired trigger has crept back -- e.g. from an older
# checkout, or a restored /etc. "retired" is the healthy answer.
redetect_triggers_state() {
    local u back=()
    for u in "${REDETECT_UNITS_RETIRED[@]}"; do
        [[ -f "/etc/systemd/system/$u" ]] && back+=("${u%.service}")
    done
    [[ -f "$UDEV_DEST" ]] && back+=("udev-rule")
    if [[ ${#back[@]} -eq 0 ]]; then
        echo "retired (native HDMI re-detects by itself)"
    else
        echo "STILL PRESENT: ${back[*]} -- run --install to remove"
    fi
}

# Undoes the automatic re-detect triggers. Idempotent, and safe to run on a
# machine that never had them. Kept as its own function so it also runs from
# --boot, which is what removes them again if a restored /etc brings them back.
retire_redetect_triggers() {
    local u changed=0
    for u in "${REDETECT_UNITS_RETIRED[@]}"; do
        if systemctl is-enabled --quiet "$u" 2>/dev/null; then
            log "disabling $u (native HDMI re-detects by itself)"
            systemctl disable "$u" >/dev/null 2>&1 || warn "could not disable $u"
            changed=1
        fi
        if [[ -f "/etc/systemd/system/$u" ]]; then
            rm -f "/etc/systemd/system/$u"
            changed=1
        fi
    done

    # The udev rule fires the controller trigger. Without it the unit is inert,
    # but leave it installed and every DualSense connect blanks the screen.
    if [[ -f "$UDEV_DEST" ]]; then
        log "removing $UDEV_DEST (controller-connect re-detect)"
        rm -f "$UDEV_DEST"
        udevadm control --reload-rules || warn "could not reload udev rules"
        changed=1
    fi

    [[ $changed -eq 1 ]] && systemctl daemon-reload
    return 0
}

ensure_redetect() {
    [[ -x "$REDETECT_BIN" ]] || die "missing or non-executable $REDETECT_BIN"
    [[ -x "$HOTKEY_BIN"   ]] || die "missing or non-executable $HOTKEY_BIN"
    bash -n "$REDETECT_BIN" || die "$REDETECT_BIN does not parse -- refusing to install"
    python3 -m py_compile "$HOTKEY_BIN" \
        || die "$HOTKEY_BIN does not compile -- refusing to install"

    retire_redetect_triggers

    local u src reload=0
    for u in "${REDETECT_UNITS_ENABLED[@]}" "${REDETECT_UNITS_TRIGGERED[@]}"; do
        src="$REPO_DIR/systemd/$u"
        [[ -f "$src" ]] || die "missing $src"
        if [[ ! -f "/etc/systemd/system/$u" ]] || ! cmp -s "$src" "/etc/systemd/system/$u"; then
            log "installing /etc/systemd/system/$u"
            install -Dm644 "$src" "/etc/systemd/system/$u"
            reload=1
        fi
    done
    [[ $reload -eq 1 ]] && systemctl daemon-reload

    for u in "${REDETECT_UNITS_ENABLED[@]}"; do
        systemctl is-enabled --quiet "$u" 2>/dev/null || systemctl enable "$u"
    done

    # The hotkey is the trigger you reach for when the screen is already black,
    # so a daemon that is installed-but-dead is the one failure worth catching
    # here rather than at 9pm from the couch.
    systemctl restart steam-machine-display-hotkey.service || \
        warn "could not start the hotkey daemon"
    sleep 1
    systemctl is-active --quiet steam-machine-display-hotkey.service || \
        warn "hotkey daemon is not running -- check: journalctl -u steam-machine-display-hotkey"
}

# The `wayland` shell function is sourced from the repo rather than copied into
# .bashrc, so editing bashrc.d/wayland.sh takes effect in the next shell with no
# reinstall. Guarded by a marker comment so this stays idempotent.
ensure_bashrc() {
    [[ -f "$BASHRC" ]] || { warn "$BASHRC does not exist -- skipping shell function"; return 0; }
    if grep -qF "$BASHRC_MARKER" "$BASHRC"; then
        return 0
    fi
    log "adding wayland shell function to $BASHRC"
    printf '\n%s\n[[ -f %s ]] && . %s\n' \
        "$BASHRC_MARKER" "$BASHRC_SNIPPET" "$BASHRC_SNIPPET" >> "$BASHRC"
    chown deck:deck "$BASHRC" 2>/dev/null || true
}

# The GUI twin of the shell function, for people not sitting at a terminal.
# The Exec path is substituted rather than shipped literal so the repo can live
# anywhere; the .desktop files themselves are disposable, the script is not.
#
# Plasma will not launch a desktop file dropped in ~/Desktop unless it is
# executable, hence 0755 -- matching SteamOS's own Return.desktop.
ensure_desktop_entry() {
    local dest dir
    for dest in "${DESKTOP_DESTS[@]}"; do
        dir="$(dirname "$dest")"
        if [[ ! -d "$dir" ]]; then
            warn "$dir does not exist -- skipping $dest"
            continue
        fi
        log "installing $dest"
        sed "s|@BIN@|$SWITCH_BIN|g" "$DESKTOP_SRC" > "$dest"
        chmod 0755 "$dest"
        chown deck:deck "$dest" 2>/dev/null || true
    done
    chmod 0755 "$SWITCH_BIN"
}

do_install() {
    need_root
    [[ -f "$MODPROBE_SRC"   ]] || die "missing $MODPROBE_SRC"
    [[ -f "$KEEP_SRC"       ]] || die "missing $KEEP_SRC"
    [[ -f "$BASHRC_SNIPPET" ]] || die "missing $BASHRC_SNIPPET"
    [[ -f "$SWITCH_BIN"     ]] || die "missing $SWITCH_BIN"
    [[ -f "$DESKTOP_SRC"    ]] || die "missing $DESKTOP_SRC"

    log "installing $MODPROBE_DEST"
    install -Dm644 "$MODPROBE_SRC" "$MODPROBE_DEST"

    log "installing $KEEP_DEST (survives SteamOS A/B updates)"
    install -Dm644 "$KEEP_SRC" "$KEEP_DEST"

    ensure_shim
    ensure_unit
    ensure_redetect
    ensure_bashrc
    ensure_desktop_entry

    # amdgpu is not in the initramfs on this machine, so /etc/modprobe.d is read
    # directly at module load. Warn if that ever stops being true, because then
    # the initramfs would hold a stale copy and this config would be ignored.
    # Resolved from pkgbase, not $(uname -r): Arch names the image after the package (initramfs-linux-neptune-616-drm-exec.img), so the old /boot/initramfs-$(uname -r).img never existed and this guard silently never fired -- lsinitcpio on a missing file prints nothing and grep -q matches nothing.
    local _pkgbase _img
    _pkgbase="$(cat "/usr/lib/modules/$(uname -r)/pkgbase" 2>/dev/null || true)"
    _img="/boot/initramfs-${_pkgbase}.img"
    # The hand-built FRL kernel has no pkgbase (it is not a pacman package) and
    # keeps its images in /boot/frl/ so that GRUB's 10_linux never globs them --
    # see ../kernel/README.md. Without this, every run warns on that kernel.
    if [[ -z "$_pkgbase" && -f /boot/frl/initramfs-linux-frlprobe.img ]]; then
        _img="/boot/frl/initramfs-linux-frlprobe.img"
        _pkgbase="linux-frlprobe"
    fi
    if [[ -z "$_pkgbase" || ! -f "$_img" ]]; then
        warn "cannot locate the initramfs for $(uname -r) -- skipping the amdgpu-in-initramfs check"
    elif lsinitcpio "$_img" 2>/dev/null | grep -q 'amdgpu\.ko'; then
        warn "amdgpu is now inside the initramfs -- run 'mkinitcpio -P' as well"
    fi

    log "done -- reboot for this to take effect"
    echo
    do_status
}

# Whether VRR is actually engaged, and whether the display is being driven as
# one pipe or two. Both need debugfs, which is root-only.
#
# The ODM part matters because a vertical seam down the centre of the screen was
# once blamed on freesync_pcon_allow_all=1 (see README). It is not caused by
# that parameter: ODM 2:1 combine is on regardless, because 4K120 exceeds what
# one DCN pipe can clock out. Eyeballing the seam is not a measurement; this is.
DBG_DIR="/sys/kernel/debug/dri/0000:03:00.0"

do_pipeline() {
    echo
    if [[ $EUID -ne 0 ]]; then
        echo "VRR / pipe topology:       (needs root -- re-run with sudo -A)"
        return 0
    fi

    local range
    range="$(tr '\n' ' ' < "$DBG_DIR/DP-1/vrr_range" 2>/dev/null || true)"
    echo "VRR:"
    printf '  %-24s %s\n' "sink vrr_range" "${range:-unavailable}"
    if [[ "$range" =~ Min:\ 0\ +Max:\ 0 ]]; then
        printf '  %-24s %s\n' "engaged" "no (sink reports no VRR range)"
    else
        printf '  %-24s %s\n' "engaged" "possibly -- range is non-zero"
    fi

    # One line per active HUBP (display pipe) feeding the surface. Two lines of
    # equal width == ODM 2:1: the frame is split and stitched at the midpoint.
    local dtn active
    dtn="$(cat "$DBG_DIR/amdgpu_dm_dtn_log" 2>/dev/null || true)"
    if [[ -z "$dtn" ]]; then
        echo "pipe topology:             unavailable"
        return 0
    fi

    # The DTN log's row label is "[ 0]:" -- a space inside the brackets, so awk
    # splits it into two fields and every column is shifted by one. Hence $5/$6
    # for width/height and $14 for underflow, not $4/$5 and $13. Three later
    # sections also start with "HUBP:", so the header match is anchored on the
    # "format" column that only the first one has.
    echo "pipe topology:"
    active="$(awk '/^HUBP: +format/{f=1;next} /^[[:space:]]*$/{f=0}
                   f && $5+0 > 0 { idx=$2; sub(/\]:/,"",idx);
                                   printf "  pipe %s  %sx%s\n", idx, $5, $6 }' <<<"$dtn")"
    if [[ -z "$active" ]]; then
        echo "  (no active pipes)"
    else
        printf '%s\n' "$active"
        local n; n="$(grep -c . <<<"$active")"
        if [[ "$n" -ge 2 ]]; then
            # NOT "so that is the seam": ODM 2:1 is on for every 4K mode above
            # 60 Hz and ran seam-free for two days straight. It is necessary for
            # the artefact but demonstrably not sufficient. See README.
            printf '  %-24s %s\n' "=>" "ODM ${n}:1 combine (normal at 4K100/120 -- required, and not the seam on its own)"
        else
            printf '  %-24s %s\n' "=>" "single pipe, no ODM"
        fi
    fi

    printf '  %-24s %s\n' "underflow" \
        "$(awk '/^HUBP: +format/{f=1;next} /^[[:space:]]*$/{f=0}
                f && $5+0 > 0 && $14 != "0h" {bad=1}
                END{print bad?"NON-ZERO -- bandwidth problem":"0 (clean)"}' <<<"$dtn")"
}

# One command to capture everything the seam investigation has ever needed, so
# the next sighting produces evidence instead of another theory. Every previous
# attempt to explain this artefact was built on a single before/after eyeball
# with an uncontrolled variable; the fields below are the ones that turned out
# to matter. Cheap and read-only -- no modeset, safe to run while it is visible.
do_seam() {
    need_root
    echo "=== seam capture: $(date -Is) ==="
    echo "uptime:        $(uptime -p)"
    echo -n "session:       "
    if pgrep -x gamescope >/dev/null 2>&1; then echo "game mode (gamescope, wayland)"
    elif pgrep -x kwin_wayland >/dev/null 2>&1; then echo "desktop, wayland"
    elif pgrep -x kwin_x11 >/dev/null 2>&1; then echo "desktop, X11"
    else echo "unknown"; fi

    local d="$DBG_DIR/DP-1"
    # Counted from the END of the row: "... htot vtot underflow blank_en", so
    # htot is NF-3 and vtot NF-2. Deliberately not fixed column numbers -- the
    # OTG section labels rows "[0]:" while the HUBP section uses "[ 0]:", and
    # that one space shifts every field, which has now cost two wrong readings.
    echo -n "mode:          "
    awk '/^OTG:/{getline; h=$(NF-3); v=$(NF-2);
                 printf "htot %s x vtot %s -> %.0f MHz at 120 Hz, %.0f at 60\n",
                        h, v, h*v*120/1e6, h*v*60/1e6; exit}' \
        "$DBG_DIR/amdgpu_dm_dtn_log" 2>/dev/null || echo "unavailable"
    printf '%-14s %s\n' "link:"  "$(tr -d '\0' < "$d/link_settings" 2>/dev/null | tr '\n' ' ')"
    printf '%-14s %s\n' "dsc_en:" "$(tr -d '\0' < "$d/dsc_clock_en" 2>/dev/null)"
    printf '%-14s %s\n' "dsc_bpp:" "$(tr -d '\0' < "$d/dsc_bits_per_pixel" 2>/dev/null) (16ths)"
    printf '%-14s %s\n' "slice_w:" "$(tr -d '\0' < "$d/dsc_slice_width" 2>/dev/null)"
    printf '%-14s %s\n' "vrr:"    "$(tr -d '\0' < "$d/vrr_range" 2>/dev/null | tr '\n' ' ')"
    do_pipeline
    echo
    # grep -c exits 1 on zero matches, which under `set -euo pipefail` would
    # kill the script at the last line and truncate the capture. Counted in
    # bash instead.
    local hits
    hits="$(dmesg 2>/dev/null | grep -cE 'link train|retrain|dp_.*fail' || true)"
    echo "link retrain/failure messages since boot: ${hits:-0}"
}

do_status() {
    echo "kernel:                    $(uname -r)"
    echo -n "modprobe.d config:         "
    if [[ -f "$MODPROBE_DEST" ]] && cmp -s "$MODPROBE_SRC" "$MODPROBE_DEST"; then
        echo "installed (matches repo)"
    elif [[ -f "$MODPROBE_DEST" ]]; then
        echo "installed but DIFFERS from repo"
    else
        echo "NOT installed"
    fi

    echo -n "atomic-update keep entry:  "
    [[ -f "$KEEP_DEST" ]] && echo "installed" || echo "NOT installed (will be lost on OS update)"

    # The shim is the thing that stops Steam's Desktop button landing on X11.
    # Reported by content, and by what PATH actually resolves -- installing the
    # file is not the same as it being the one that gets run.
    echo -n "session-select shim:       "
    if shim_ok; then
        echo "installed (matches repo)"
    elif [[ -e "$SHIM_DEST" ]]; then
        echo "installed but DIFFERS from repo"
    else
        echo "NOT installed -- Steam's Desktop button will land on X11"
    fi

    echo -n "  resolved on PATH:        "
    local resolved
    resolved="$(PATH="/usr/local/sbin:/usr/local/bin:/usr/bin" command -v steamos-session-select 2>/dev/null || true)"
    if [[ "$resolved" == "$SHIM_DEST" ]]; then
        echo "$resolved (shim wins)"
    else
        echo "${resolved:-not found} -- expected $SHIM_DEST"
    fi

    echo -n "  'plasma' maps to:        "
    if [[ -x "$SHIM_DEST" ]]; then
        STEAM_MACHINE_SESSION_DRYRUN=1 "$SHIM_DEST" plasma 2>&1 | sed 's/^dry run: would exec //'
    else
        echo "plasmax11.desktop (Valve default -- no colour management)"
    fi

    echo -n "boot self-heal unit:       "
    if [[ -f "$UNIT_DEST" ]] && cmp -s "$UNIT_SRC" "$UNIT_DEST"; then
        if systemctl is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
            echo "installed and enabled"
        else
            echo "installed but NOT enabled -- shim will be lost on the next OS update"
        fi
    elif [[ -f "$UNIT_DEST" ]]; then
        echo "installed but DIFFERS from repo"
    else
        echo "NOT installed -- shim will be lost on the next OS update"
    fi

    # The whole point of the shim, so say plainly which one is live.
    echo
    # Detected from the running compositor, not from $XDG_SESSION_TYPE: sudo
    # strips that variable, and logind reports Type=unspecified for the session
    # sddm-helper-start-x11user creates here, so both of the obvious sources
    # answer "unknown" exactly when this is run the way it usually is.
    echo -n "current session:           "
    if pgrep -x gamescope >/dev/null 2>&1; then
        echo "game mode (gamescope, wayland)"
    elif pgrep -x kwin_wayland >/dev/null 2>&1; then
        echo "desktop, wayland (colour management available)"
    elif pgrep -x kwin_x11 >/dev/null 2>&1; then
        echo "desktop, X11 -- NO colour management: HDR/WCG/ICC are KWin Wayland-only,"
        echo "                           so colours go unmanaged to the OLED and look over-saturated."
        echo "                           Fix: run 'wayland' in a shell, or the Switch to Wayland desktop icon."
    else
        echo "${XDG_SESSION_TYPE:-unknown}"
    fi

    # These two live under /home/deck, which is its own partition -- untouched by
    # SteamOS A/B updates, so they need no keep entry.
    echo -n "wayland shell function:    "
    if [[ -f "$BASHRC" ]] && grep -qF "$BASHRC_MARKER" "$BASHRC"; then
        echo "sourced from .bashrc"
    else
        echo "NOT wired into .bashrc"
    fi

    echo -n "desktop shortcut:          "
    local d found=0 missing=0
    for d in "${DESKTOP_DESTS[@]}"; do
        [[ -f "$d" ]] && found=$((found + 1)) || missing=$((missing + 1))
    done
    if [[ $missing -eq 0 ]]; then
        echo "installed ($found)"
    else
        echo "$found of ${#DESKTOP_DESTS[@]} installed"
    fi

    echo
    echo "TV re-detect triggers:"
    local u state
    for u in "${REDETECT_UNITS_ENABLED[@]}"; do
        state="$(systemctl is-enabled "$u" 2>/dev/null || echo missing)"
        # The hotkey daemon is the only long-running one, so it is the only one
        # where "enabled" and "actually running" can disagree.
        if [[ "$u" == steam-machine-display-hotkey.service ]]; then
            state="$state, $(systemctl is-active "$u" 2>/dev/null || echo inactive)"
        fi
        printf '  %-46s %s\n' "${u%.service}" "$state"
    done
    printf '  %-46s %s\n' "auto re-detect triggers" \
        "$(redetect_triggers_state)"
    local t
    for t in controller boot resume hotkey; do
        if [[ -f "/run/steam-machine-display-redetect.$t.stamp" ]]; then
            printf '  %-46s %s\n' "last fired ($t)" \
                "$(( $(date +%s) - $(stat -c %Y "/run/steam-machine-display-redetect.$t.stamp") ))s ago"
        fi
    done

    echo
    echo "live amdgpu parameters:"
    printf '  %-26s %s\n' "freesync_pcon_allow_all" "$(param freesync_pcon_allow_all)"
    printf '  %-26s %s\n' "deep_color"              "$(param deep_color)"
    printf '  %-26s %s\n' "dcfeaturemask"           "$(param dcfeaturemask)"

    # Compare the live value against whatever the repo config actually asks for,
    # rather than assuming a particular value is the desired one -- that setting
    # has been flipped once already (see modprobe.d/amdgpu-display.conf).
    local want
    want="$(sed -n 's/^options amdgpu .*freesync_pcon_allow_all=\([0-9]\+\).*/\1/p' \
        "$MODPROBE_SRC" | head -1)"
    if [[ -n "$want" && "$(param freesync_pcon_allow_all)" != "$want" ]]; then
        echo
        warn "config wants freesync_pcon_allow_all=$want but live value is $(param freesync_pcon_allow_all) -- reboot required"
    fi

    echo
    echo "connectors:"
    local c
    for c in /sys/class/drm/card0-*; do
        [[ -f "$c/status" ]] || continue
        printf '  %-24s %s\n' "$(basename "$c")" "$(cat "$c/status")"
    done

    do_pipeline

    echo
    echo "native HDMI 2.1 FRL:       "
    if [[ -f /proc/config.gz ]] || true; then
        echo "  unavailable on this kernel (needs Linux 7.2+; DC_FRL_MASK absent)"
    fi
}

# Run at every boot by steam-machine-display.service.
#
# No fast-path early exit before the repairs: the whole point is to run after an
# A/B update has silently deleted things, and the file that has been deleted is
# not the file you would test for.
#
# The two /etc files are already covered by the atomic-update keep entry, but
# that only helps if the drop-in was in place when the update ran -- and it is
# no help at all if the keep entry itself was never installed. Cheap to check.
do_boot() {
    need_root
    if [[ ! -f "$MODPROBE_DEST" ]] || ! cmp -s "$MODPROBE_SRC" "$MODPROBE_DEST"; then
        log "restoring $MODPROBE_DEST"
        install -Dm644 "$MODPROBE_SRC" "$MODPROBE_DEST"
        warn "amdgpu options were missing or stale -- they only take effect at the next reboot"
    fi
    if [[ ! -f "$KEEP_DEST" ]] || ! cmp -s "$KEEP_SRC" "$KEEP_DEST"; then
        log "restoring $KEEP_DEST"
        install -Dm644 "$KEEP_SRC" "$KEEP_DEST"
    fi
    ensure_shim
    ensure_unit
    ensure_redetect
}

do_uninstall() {
    need_root
    systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_DEST"
    local u
    for u in "${REDETECT_UNITS_ENABLED[@]}"; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
    done
    for u in "${REDETECT_UNITS_ENABLED[@]}" "${REDETECT_UNITS_TRIGGERED[@]}"; do
        rm -f "/etc/systemd/system/$u"
    done
    if [[ -f "$UDEV_DEST" ]]; then
        rm -f "$UDEV_DEST"
        udevadm control --reload-rules || true
    fi
    systemctl daemon-reload
    if [[ -e "$SHIM_DEST" ]]; then
        trap relock_rootfs EXIT
        unlock_rootfs
        rm -f "$SHIM_DEST"
        relock_rootfs
        RO_WAS_ENABLED=0
        trap - EXIT
    fi
    rm -f "$MODPROBE_DEST" "$KEEP_DEST" "${DESKTOP_DESTS[@]}"
    # The .bashrc line is left alone deliberately -- it is a two-line edit to a
    # file the user owns, and blind sed on someone's .bashrc is a bad trade.
    log "removed -- reboot to revert the module parameters"
    log "the 'wayland' function is still sourced from $BASHRC; remove it by hand if unwanted"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --status)     do_status ;;
    --boot)       do_boot ;;
    --seam)       do_seam ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
