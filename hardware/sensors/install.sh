#!/usr/bin/env bash
# Full hardware sensor coverage for this build: fan RPM, Vcore and VRM temps
# from the ITE IT8696E Super I/O (out-of-tree it87), SATA SSD temps
# (drivetemp), DDR5 DIMM temps (spd5118), and the FCH SMBus that the last of
# those needs.
#
#   ./install.sh              full install (build, install, boot config, load)
#   ./install.sh --no-smbus   install everything EXCEPT the acpi_enforce_resources
#                             boot parameter -- no SMBus, so no DIMM temps
#   ./install.sh --boot       boot-time path: restore it87 from cache if /usr was
#                             reset by a SteamOS update; rebuild only if needed
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall
#
# Everything authoritative lives under /home (this repo + ~/.cache), because
# SteamOS replaces the whole /usr tree on every A/B update.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$REPO_DIR/it87/upstream"
BASELINE_DIR="$REPO_DIR/baseline"
CACHE_DIR="${IT87_CACHE:-/home/deck/.cache/steam-machine-sensors}"
BUILD_DIR="$CACHE_DIR/build"
MODCACHE_DIR="$CACHE_DIR/modules"

KVER="$(uname -r)"
MODNAME="it87"
MOD_DEST_DIR="/usr/lib/modules/$KVER/updates"
GRUB_DROPIN="/etc/default/grub.d/60-steam-machine-smbus.cfg"
CMDLINE_PARAM="acpi_enforce_resources=lax"

# In-tree, present in the SteamOS kernel but not auto-loaded.
INTREE_MODULES=(drivetemp spd5118)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (use sudo -A)"; }

# --- SteamOS read-only rootfs -------------------------------------------------
RO_WAS_ENABLED=0
unlock_rootfs() {
    if command -v steamos-readonly >/dev/null 2>&1; then
        if [[ "$(steamos-readonly status 2>/dev/null)" == "enabled" ]]; then
            RO_WAS_ENABLED=1
            log "unlocking read-only rootfs"
            steamos-readonly disable
        fi
    fi
}
relock_rootfs() {
    if [[ $RO_WAS_ENABLED -eq 1 ]] && command -v steamos-readonly >/dev/null 2>&1; then
        log "restoring read-only rootfs"
        steamos-readonly enable || warn "could not re-enable read-only rootfs"
    fi
}

# --- helpers ------------------------------------------------------------------
# NB: not `lsmod | grep -q` -- under `set -o pipefail`, grep -q exits on the
# first match, lsmod dies of SIGPIPE, and the whole pipeline reports failure.
module_loaded() {
    local out; out="$(lsmod)"
    [[ "$out" == *$'\n'"$1 "* || "$out" == "$1 "* ]]
}

module_installed() { compgen -G "$MOD_DEST_DIR/$MODNAME.ko*" >/dev/null 2>&1; }

# Hash of the vendored source, so edits to it invalidate the cached build
# instead of silently reinstalling a stale module.
src_hash() {
    find "$SRC_DIR" -type f -print0 | sort -z | xargs -0 sha256sum \
        | sha256sum | cut -d' ' -f1
}

cached_module() {
    local ko="$MODCACHE_DIR/$KVER/$MODNAME.ko"
    local hf="$MODCACHE_DIR/$KVER/$MODNAME.srchash"
    [[ -f "$ko" && -f "$hf" ]] || return 1
    [[ "$(<"$hf")" == "$(src_hash)" ]]
}

smbus_active()  { i2cdetect -l 2>/dev/null | grep -qi 'piix4'; }
smbus_enabled() { grep -q "$CMDLINE_PARAM" /proc/cmdline; }
spd_bound()     { compgen -G "/sys/bus/i2c/drivers/spd5118/*-005*" >/dev/null 2>&1; }

# --- dependency install -------------------------------------------------------
# SteamOS ships with the pacman keyring uninitialised -- it isn't meant to be
# used for installing packages -- and an A/B update can reset /etc.
ensure_keyring() {
    local keycount
    keycount="$(pacman-key --list-keys 2>/dev/null | grep -c '^pub' || true)"
    [[ "${keycount:-0}" -gt 0 ]] && return 0

    local keyrings=() k
    for k in archlinux holo; do
        [[ -f "/usr/share/pacman/keyrings/$k.gpg" ]] && keyrings+=("$k")
    done
    [[ ${#keyrings[@]} -gt 0 ]] || { warn "no pacman keyrings found to populate"; return 1; }

    log "initialising pacman keyring (${keyrings[*]})"
    pacman-key --init >/dev/null 2>&1 || { warn "pacman-key --init failed"; return 1; }
    pacman-key --populate "${keyrings[@]}" >/dev/null 2>&1 \
        || { warn "pacman-key --populate failed"; return 1; }
}

install_build_deps() {
    local pkgbase headers missing=()
    pkgbase="$(cat "/usr/lib/modules/$KVER/pkgbase" 2>/dev/null || true)"
    [[ -n "$pkgbase" ]] || die "cannot determine kernel pkgbase for $KVER"
    headers="${pkgbase}-headers"

    [[ -d "/usr/lib/modules/$KVER/build" ]] || missing+=("$headers")
    command -v gcc  >/dev/null 2>&1 || missing+=(gcc)
    command -v make >/dev/null 2>&1 || missing+=(make)

    if [[ ${#missing[@]} -eq 0 ]]; then
        log "build dependencies already present"
        return 0
    fi

    ensure_keyring || return 1

    log "installing build dependencies: ${missing[*]}"
    # -Sy (not -Syu): never trigger a partial system upgrade on SteamOS.
    if ! pacman -Sy --needed --noconfirm "${missing[@]}"; then
        warn "pacman failed; is the network up?"
        return 1
    fi
    [[ -d "/usr/lib/modules/$KVER/build" ]] \
        || { warn "$headers installed but .../build is still missing"; return 1; }
}

# --- build --------------------------------------------------------------------
build_module() {
    log "building $MODNAME for kernel $KVER"
    rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
    cp "$SRC_DIR"/it87.c "$SRC_DIR"/compat.h "$SRC_DIR"/Makefile "$BUILD_DIR/"

    make -C "$BUILD_DIR" TARGET="$KVER" >/dev/null || die "module build failed"
    [[ -f "$BUILD_DIR/$MODNAME.ko" ]] || die "build produced no $MODNAME.ko"

    mkdir -p "$MODCACHE_DIR/$KVER"
    install -Dm644 "$BUILD_DIR/$MODNAME.ko" "$MODCACHE_DIR/$KVER/$MODNAME.ko"
    src_hash > "$MODCACHE_DIR/$KVER/$MODNAME.srchash"
    # Written by root but lives under the user's home; keep it user-owned so it
    # can be inspected and cleaned without sudo.
    chown -R deck:deck "$CACHE_DIR" 2>/dev/null || true
    log "cached module at $MODCACHE_DIR/$KVER/$MODNAME.ko"
}

install_module() {
    log "installing module -> $MOD_DEST_DIR/$MODNAME.ko"
    install -Dm644 "$MODCACHE_DIR/$KVER/$MODNAME.ko" "$MOD_DEST_DIR/$MODNAME.ko"
    depmod -a "$KVER"
}

# --- system configuration -----------------------------------------------------
# repo-relative source -> absolute destination, for everything we drop in /etc.
# The grub drop-in is handled separately (it needs update-grub), and the systemd
# unit is not listed because it is already on SteamOS's default keep list and
# restoring it at boot would be pointless -- if it were missing, nothing would be
# running to restore it.
declare -A ETC_CONFIG=(
    ["modules-load.d/steam-machine-sensors.conf"]="/etc/modules-load.d/steam-machine-sensors.conf"
    ["modprobe.d/steam-machine-sensors.conf"]="/etc/modprobe.d/steam-machine-sensors.conf"
    ["sensors.d/steam-machine.conf"]="/etc/sensors.d/steam-machine.conf"
    ["atomic-update.conf.d/steam-machine-sensors.conf"]="/etc/atomic-update.conf.d/steam-machine-sensors.conf"
)

# Reinstall any of the above that is missing or modified. Cheap and idempotent,
# so it is safe on the boot fast path. /etc is an overlayfs with its upper layer
# in /var, writable even when steamos-readonly is enabled, so no unlock_rootfs.
ensure_etc_config() {
    local src
    for src in "${!ETC_CONFIG[@]}"; do
        if ! cmp -s "$REPO_DIR/$src" "${ETC_CONFIG[$src]}"; then
            install -Dm644 "$REPO_DIR/$src" "${ETC_CONFIG[$src]}"
            warn "restored ${ETC_CONFIG[$src]} (was missing or modified)"
        fi
    done
}

install_system_config() {
    log "installing modprobe / modules-load / sensors configuration"
    local src
    for src in "${!ETC_CONFIG[@]}"; do
        install -Dm644 "$REPO_DIR/$src" "${ETC_CONFIG[$src]}"
    done
    install -Dm644 "$REPO_DIR/systemd/steam-machine-sensors.service" \
        /etc/systemd/system/steam-machine-sensors.service
    systemctl daemon-reload
    systemctl enable steam-machine-sensors.service >/dev/null 2>&1 \
        || warn "could not enable steam-machine-sensors.service"

    # `label`/`ignore` are applied by libsensors at read time, but `set` writes
    # thresholds into the chip and only happens on `sensors -s`. Without it the
    # IT8696E keeps its 10 RPM default fan minimums and alarms permanently.
    # lm_sensors.service is the stock unit that does this on every boot; it
    # ships disabled on SteamOS.
    sensors -s 2>/dev/null || warn "sensors -s failed"
    if systemctl list-unit-files lm_sensors.service >/dev/null 2>&1; then
        systemctl enable lm_sensors.service >/dev/null 2>&1 \
            || warn "could not enable lm_sensors.service"
    fi
}

# Take a zero-bus-traffic record of what the DIMMs report *before* the SMBus is
# ever exposed, so SPD corruption is detectable later. See bin/spd-check.sh.
capture_spd_baseline() {
    local f="$BASELINE_DIR/dmidecode-t17.txt"
    if [[ -s "$f" ]]; then
        log "SPD baseline already present ($f)"
        return 0
    fi
    log "capturing DDR5 SPD baseline -> $f"
    mkdir -p "$BASELINE_DIR"
    dmidecode -t 17 > "$f" || { warn "dmidecode failed; no baseline captured"; return 1; }
    chown deck:deck "$f" 2>/dev/null || true
}

enable_smbus() {
    # The baseline must exist before the bus is ever reachable, not after.
    capture_spd_baseline || die "refusing to enable SMBus without an SPD baseline"

    # Compare content, not mere existence. Checking only `-f` plus "is the
    # parameter live" meant any later edit to the repo's drop-in silently never
    # reached /etc -- the installer reported success and changed nothing, and
    # --status then reported drift that a re-run could not clear.
    if cmp -s "$REPO_DIR/default-grub.d/60-steam-machine-smbus.cfg" "$GRUB_DROPIN" && smbus_enabled; then
        log "SMBus boot parameter already installed and active"
        return 0
    fi
    if [[ -f "$GRUB_DROPIN" ]] && smbus_enabled; then
        log "SMBus drop-in differs from the repo -- reinstalling"
    fi

    log "installing grub drop-in -> $GRUB_DROPIN"
    install -Dm644 "$REPO_DIR/default-grub.d/60-steam-machine-smbus.cfg" "$GRUB_DROPIN"

    log "regenerating /efi/EFI/steamos/grub.cfg"
    update-grub >/dev/null 2>&1 || die "update-grub failed"

    if ! smbus_enabled; then
        warn "$CMDLINE_PARAM is staged but not on the running kernel -- reboot to apply"
        warn "DIMM temperatures will not appear until then"
    fi
}

load_modules() {
    local m
    for m in "${INTREE_MODULES[@]}" "$MODNAME"; do
        module_loaded "$m" && continue
        modprobe "$m" 2>/dev/null || warn "modprobe $m failed"
    done
    # Only meaningful once the SMBus exists; harmless before then.
    if smbus_active && ! spd_bound; then
        warn "SMBus is up but spd5118 has bound nothing -- check: i2cdetect -l"
    fi
}

# --- status -------------------------------------------------------------------
do_status() {
    local m
    echo "kernel:              $KVER"
    echo -n "it87 installed:      "; module_installed && echo "yes" || echo "NO"
    echo -n "it87 cached:         "; cached_module && echo "yes ($KVER)" || echo "no"
    echo "modules loaded:"
    for m in "${INTREE_MODULES[@]}" "$MODNAME"; do
        printf '  %-12s %s\n' "$m" "$(module_loaded "$m" && echo yes || echo NO)"
    done
    echo -n "grub drop-in:        "; [[ -f "$GRUB_DROPIN" ]] && echo "$GRUB_DROPIN" || echo "not installed"
    echo -n "SMBus param active:  "; smbus_enabled && echo "yes" || echo "no (reboot pending?)"
    echo -n "SMBus adapters:      "; smbus_active && echo "yes" || echo "NO"
    echo -n "spd5118 bound:       "
    if spd_bound; then
        echo "yes ($(ls /sys/bus/i2c/drivers/spd5118/ 2>/dev/null | grep -c '^[0-9]*-00' ) devices)"
    else
        echo "no"
    fi
    echo -n "SPD baseline:        "; [[ -s "$BASELINE_DIR/dmidecode-t17.txt" ]] && echo "present" || echo "MISSING"
    echo -n "A/B update keep:     "
    if [[ -f /etc/atomic-update.conf.d/steam-machine-sensors.conf ]]; then
        echo "installed (/etc config survives OS updates)"
    else
        echo "MISSING (/etc config will be lost on next OS update)"
    fi
    local src missing=0
    for src in "${!ETC_CONFIG[@]}"; do
        [[ -f "${ETC_CONFIG[$src]}" ]] || { printf '  MISSING: %s\n' "${ETC_CONFIG[$src]}"; missing=1; }
    done
    [[ $missing -eq 1 ]] && warn "re-run ./install.sh (or reboot: --boot restores these)"
    echo
    echo "hwmon chips:"
    for h in /sys/class/hwmon/hwmon*; do
        printf '  %-18s %s\n' "$(cat "$h/name" 2>/dev/null)" "$h"
    done
}

# --- top level ----------------------------------------------------------------
do_install() {
    local want_smbus=$1
    need_root
    trap relock_rootfs EXIT
    unlock_rootfs

    if ! cached_module; then
        install_build_deps || die "could not install build dependencies"
        build_module
    else
        log "using cached module for $KVER"
    fi

    install_module
    install_system_config

    if [[ $want_smbus -eq 1 ]]; then
        enable_smbus
    else
        log "skipping SMBus boot parameter (--no-smbus); DIMM temps unavailable"
    fi

    load_modules
    log "done"
    echo
    do_status
}

# Boot path: /usr may have been wiped by a SteamOS update. Restore from the
# cache (fast, offline). Only rebuild if the kernel version changed.
do_boot() {
    need_root
    trap relock_rootfs EXIT

    # Only an allowlisted subset of /etc carries into a new OS image, and none of
    # these paths is on the default list -- hence the atomic-update.conf.d entry
    # that allowlists them. This restores them anyway if that entry was itself
    # missing (e.g. an update that predates it) rather than only complaining.
    # Runs before the module work below: the modprobe softdep must be in place
    # before load_modules() brings i2c_piix4 up.
    ensure_etc_config

    # A SteamOS update writes a fresh grub.cfg for the slot it installs into.
    # If it regenerated that from grub-mkconfig our drop-in was picked up and
    # there is nothing to do; if it dropped in a canned config instead, the
    # parameter is silently gone and DIMM temps disappear with it.
    #
    # Detect exactly that: drop-in present, parameter absent from the kernel we
    # actually booted. Regenerating fixes the *next* boot, so warn as well --
    # this run has no SMBus regardless.
    # Kept out of ensure_etc_config because putting the file back is only half
    # the job -- grub.cfg has to be regenerated before it reaches the kernel.
    if [[ ! -f "$GRUB_DROPIN" ]]; then
        install -Dm644 "$REPO_DIR/default-grub.d/60-steam-machine-smbus.cfg" "$GRUB_DROPIN"
        warn "restored $GRUB_DROPIN (was missing)"
    fi

    if ! smbus_enabled; then
        warn "$CMDLINE_PARAM missing from the running kernel -- regenerating grub.cfg"
        unlock_rootfs
        update-grub >/dev/null 2>&1 \
            && warn "restored; DIMM temps return after the next reboot" \
            || warn "update-grub failed -- re-run ./install.sh manually"
    fi

    if ! module_installed; then
        unlock_rootfs
        if ! cached_module; then
            # Kernel changed (or first run): needs network for headers.
            local tries=0
            until install_build_deps; do
                tries=$((tries + 1))
                [[ $tries -ge 5 ]] && die "giving up waiting for network/pacman"
                warn "retrying dependency install in 30s ($tries/5)"
                sleep 30
            done
            build_module
        fi
        install_module
        log "restored $MODNAME for kernel $KVER"
    fi

    load_modules
}

do_uninstall() {
    need_root
    trap relock_rootfs EXIT
    unlock_rootfs
    systemctl disable --now steam-machine-sensors.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/steam-machine-sensors.service \
          "${ETC_CONFIG[@]}" \
          "$GRUB_DROPIN"
    systemctl daemon-reload
    rmmod "$MODNAME" 2>/dev/null || true
    rm -f "$MOD_DEST_DIR/$MODNAME.ko"
    depmod -a "$KVER" || true
    log "regenerating grub config without $CMDLINE_PARAM"
    update-grub >/dev/null 2>&1 || warn "update-grub failed"
    log "uninstalled (cache under $CACHE_DIR and the SPD baseline left in place)"
}

case "${1:-}" in
    ""|--install)  do_install 1 ;;
    --no-smbus)    do_install 0 ;;
    --boot)        do_boot ;;
    --status)      do_status ;;
    --uninstall)   do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
