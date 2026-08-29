#!/usr/bin/env bash
# input-remapper (https://github.com/sezanzeb/input-remapper) on SteamOS.
#
#   ./install.sh              build and install (default)
#   ./install.sh --boot       restore the system files a SteamOS update dropped,
#                             and rebuild the venv if system python moved.
#                             Run as root by steam-machine-input-remapper.service
#   ./install.sh --status     report current state and exit
#   ./install.sh --uninstall
#
# ---------------------------------------------------------------------------
# WHAT THE README'S "BUILD AGAINST KERNEL HEADERS" ACTUALLY MEANS: NOTHING HERE
#
# input-remapper has no kernel module and no DKMS. It is pure userspace: it
# reads /dev/input/event* and writes a virtual device through /dev/uinput
# (an in-tree module, already loaded here) using python-evdev. The `python3-dev`
# in upstream's instructions is only needed if pip has to BUILD python-evdev,
# which ships sdist-only on PyPI and would then want a C compiler and the Linux
# uapi headers -- neither of which this machine has.
#
# SteamOS already ships python-evdev 1.9.0, python-gobject, python-cairo and
# python-psutil, so that build never happens. Nothing is compiled by this
# script. The one genuinely missing system library is gtksourceview4, which is
# fetched as a package and unpacked into the prefix rather than installed with
# pacman.
#
# ---------------------------------------------------------------------------
# WHY /opt, AND WHAT IS LEFT IN /usr
#
# Upstream's installer (`python3 -m install --root /`) writes to /usr/bin,
# /usr/share, /usr/lib/systemd/system, /usr/lib/udev/rules.d and
# /etc/xdg/autostart, and install/module.py actively scores any site-packages
# path under /home at -50. Every one of those paths is replaced wholesale by a
# SteamOS A/B update. Installed upstream's way, input-remapper would vanish on
# the next OS update with no error -- just a GUI that no longer starts.
#
# So the application goes in /opt/input-remapper instead. /opt is a SteamOS
# offload mount living on the home partition (see system/btop/), so it is
# writable without unlocking the rootfs and survives updates on its own.
#
# Four things cannot live there, because something outside our control resolves
# them by absolute path:
#
#   /usr/bin/input-remapper-*        pkexec resolves the GUI's helper by name
#                                    through PATH, and refuses anything not
#                                    owned by root; the polkit action's
#                                    exec.path annotation names /usr/bin too.
#   /usr/share/input-remapper        inputremapper/installation_info.py has
#                                    DATA_DIR = "/usr/share/input-remapper"
#                                    hardcoded. Installed here as a symlink
#                                    into the prefix, so it costs one inode.
#   /usr/share/polkit-1/actions/     polkit reads actions from /usr only; there
#                                    is no /etc equivalent for action files.
#   /etc/dbus-1/system.d/, /etc/udev/rules.d/
#                                    the daemon owns its name on the SYSTEM bus
#                                    (dasbus SystemMessageBus, no session-bus
#                                    option in the code), and hotplug autoload
#                                    is a udev rule. Both directories are
#                                    outside the atomic-update keep list.
#
# The /etc pair is handled by atomic-update.conf.d/ plus the self-heal below.
# The /usr entries cannot be kept at all -- they are reinstalled by --boot,
# which runs before input-remapper.service on every boot.
#
# The systemd unit deliberately points at /opt, not at the /usr/bin wrapper, so
# the injection daemon still works on the first boot after an update even if
# the self-heal has not run yet.
# ---------------------------------------------------------------------------
set -euo pipefail

# Shared self-elevation (lib/elevate.sh): provides elevate() and need_root().
_lib() {
    local d; d=$(readlink -f "${BASH_SOURCE[0]}"); d=${d%/*}
    while [[ $d != / ]]; do
        [[ -r $d/lib/elevate.sh ]] && { printf '%s\n' "$d/lib/elevate.sh"; return 0; }
        d=${d%/*}
    done
    return 1
}
_l=$(_lib) && source "$_l" && source "${_l%/*}/rootfs.sh"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_USER="deck"
TARGET_HOME="/home/deck"

PREFIX="/opt/input-remapper"
SRC_DIR="$PREFIX/src"
VENV_DIR="$PREFIX/venv"
DATA_DIR="$PREFIX/share/input-remapper"
PY_MARKER="$PREFIX/.python-version"

UPSTREAM_URL="https://github.com/sezanzeb/input-remapper.git"
# Pinned to a release tag, and the tag's commit is verified after fetching --
# a tag is a movable ref, so trusting the name alone would let upstream change
# what this installs without the pin here changing at all.
UPSTREAM_REF="2.2.1"
UPSTREAM_COMMIT="e9a87d13480c3b1dee654b296578a8f4e2cd31d6"

# gtksourceview4 is the only system library input-remapper needs that SteamOS
# does not ship. Taken from Valve's own Arch mirror rather than pacman: this
# unpacks four runtime files into the prefix and leaves the rootfs alone.
GSV_PKG="gtksourceview4-4.8.4-2-x86_64.pkg.tar.zst"
GSV_URL="https://steamdeck-packages.steamos.cloud/archlinux-mirror/extra-3.8/os/x86_64/$GSV_PKG"
GSV_SHA256="cfb1cea2e2036643d51465b61eb9c70ba1626285401d4f6d9933e54f4d0ae634"

CACHE_DIR="$TARGET_HOME/.cache/steam-machine-input-remapper"

# NOT `python3`: Homebrew's 3.14 is first on deck's PATH and has none of the
# system site-packages, so a venv built from it cannot import gi or evdev.
SYS_PYTHON="/usr/bin/python3"

BINS=(input-remapper-gtk input-remapper-service input-remapper-control input-remapper-reader-service)

# Wheels pip must fetch. Everything else (evdev, psutil, PyGObject, pycairo)
# comes from the system tree via --system-site-packages, which is also why the
# venv has to be rebuilt if SteamOS bumps python's minor version.
PIP_DEPS=(dasbus pydantic packaging)

UNIT_DEST="/etc/systemd/system/input-remapper.service"
HEAL_UNIT_SRC="$REPO_DIR/systemd/steam-machine-input-remapper.service"
HEAL_UNIT_DEST="/etc/systemd/system/steam-machine-input-remapper.service"
KEEP_SRC="$REPO_DIR/atomic-update.conf.d/steam-machine-input-remapper.conf"
KEEP_DEST="/etc/atomic-update.conf.d/steam-machine-input-remapper.conf"
DBUS_DEST="/etc/dbus-1/system.d/inputremapper.Control.conf"
UDEV_DEST_DIR="/etc/udev/rules.d"
UDEV_RULES=(69-input-remapper-forwarded.rules 99-input-remapper.rules)
POLKIT_DEST="/usr/share/polkit-1/actions/input-remapper.policy"
USR_DATA_LINK="/usr/share/input-remapper"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

py_minor() { "$SYS_PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])'; }

# --- prefix construction ------------------------------------------------------

fetch_src() {
    if [[ -d "$SRC_DIR/.git" ]]; then
        log "updating $SRC_DIR"
        git -C "$SRC_DIR" fetch --tags --force origin || warn "fetch failed -- using the existing checkout"
    else
        log "cloning input-remapper $UPSTREAM_REF"
        rm -rf "$SRC_DIR"
        git clone --quiet "$UPSTREAM_URL" "$SRC_DIR" || die "clone failed"
    fi
    git -C "$SRC_DIR" checkout --quiet --force "$UPSTREAM_REF" || die "no such ref: $UPSTREAM_REF"
    local have; have="$(git -C "$SRC_DIR" rev-parse HEAD)"
    [[ "$have" == "$UPSTREAM_COMMIT" ]] \
        || die "$UPSTREAM_REF is $have, expected $UPSTREAM_COMMIT -- the tag moved; review upstream before bumping the pin"
    log "at $UPSTREAM_REF ($have)"
}

verify_gsv() { [[ -f "$CACHE_DIR/$GSV_PKG" ]] && echo "$GSV_SHA256  $CACHE_DIR/$GSV_PKG" | sha256sum -c --status; }

install_gtksourceview() {
    if ! verify_gsv; then
        [[ -f "$CACHE_DIR/$GSV_PKG" ]] && warn "cached $GSV_PKG failed checksum -- re-downloading"
        mkdir -p "$CACHE_DIR"
        log "downloading $GSV_PKG"
        curl -fsSL -o "$CACHE_DIR/$GSV_PKG.part" "$GSV_URL" || die "download failed"
        mv "$CACHE_DIR/$GSV_PKG.part" "$CACHE_DIR/$GSV_PKG"
        verify_gsv || die "checksum mismatch on $GSV_PKG -- refusing to unpack it"
        chown -R "$TARGET_USER:$TARGET_USER" "$CACHE_DIR" 2>/dev/null || true
    fi

    # Runtime only: the shared object, the typelib gi needs for
    # gi.require_version("GtkSource", "4"), and the language-spec/style data
    # GtkSource loads from XDG_DATA_DIRS. Not the headers, pkgconfig or vapi.
    log "unpacking gtksourceview4 runtime into $PREFIX"
    rm -rf "$PREFIX/lib" "$PREFIX/share/gtksourceview-4"
    mkdir -p "$PREFIX/lib" "$PREFIX/share"
    local tmp; tmp="$(mktemp -d)"
    tar --zstd -xf "$CACHE_DIR/$GSV_PKG" -C "$tmp" \
        usr/lib/libgtksourceview-4.so.0.0.0 \
        usr/lib/girepository-1.0/GtkSource-4.typelib \
        usr/share/gtksourceview-4
    install -Dm755 "$tmp/usr/lib/libgtksourceview-4.so.0.0.0" "$PREFIX/lib/libgtksourceview-4.so.0.0.0"
    ln -sfn libgtksourceview-4.so.0.0.0 "$PREFIX/lib/libgtksourceview-4.so.0"
    install -Dm644 "$tmp/usr/lib/girepository-1.0/GtkSource-4.typelib" \
        "$PREFIX/lib/girepository-1.0/GtkSource-4.typelib"
    cp -a "$tmp/usr/share/gtksourceview-4" "$PREFIX/share/"
    rm -rf "$tmp"
}

build_venv() {
    log "building venv with $SYS_PYTHON ($("$SYS_PYTHON" -V))"
    rm -rf "$VENV_DIR"
    # --system-site-packages is what makes this work with nothing compiled:
    # evdev, PyGObject, pycairo and psutil are taken from /usr/lib/python3.N.
    "$SYS_PYTHON" -m venv --system-site-packages "$VENV_DIR" || die "venv creation failed"
    log "installing python dependencies"
    "$VENV_DIR/bin/pip" install --quiet --no-cache-dir --upgrade "${PIP_DEPS[@]}" \
        || die "pip install failed"
    log "installing input-remapper $UPSTREAM_REF"
    # --no-deps: pyproject lists evdev/PyGObject/pycairo/psutil, and letting pip
    # satisfy those would pull sdists it then has to compile, which is exactly
    # what the system packages exist to avoid.
    "$VENV_DIR/bin/pip" install --quiet --no-cache-dir --no-deps "$SRC_DIR" \
        || die "installing input-remapper failed"
    py_minor > "$PY_MARKER"
}

install_prefix_data() {
    log "installing data files -> $DATA_DIR"
    rm -rf "$DATA_DIR"
    mkdir -p "$DATA_DIR"
    cp -a "$SRC_DIR"/data/. "$DATA_DIR/"
    # Compiled translations. gettext is present on SteamOS; a missing msgfmt is
    # not worth failing the install over, the GUI just falls back to English.
    if command -v msgfmt >/dev/null 2>&1; then
        local po lang
        for po in "$SRC_DIR"/po/*.po; do
            [[ -f "$po" ]] || continue
            lang="$(basename "$po" .po)"
            install -d "$DATA_DIR/lang/$lang/LC_MESSAGES"
            msgfmt -o "$DATA_DIR/lang/$lang/LC_MESSAGES/input-remapper.mo" "$po" 2>/dev/null || true
        done
    else
        warn "msgfmt not found -- the GUI will be English-only"
    fi
}

# Every entry point is the same three env vars plus the venv interpreter. They
# are set INSIDE the wrapper rather than in the unit or the caller's shell
# because pkexec scrubs the environment before exec, and udev has none at all.
write_wrappers() {
    log "writing wrappers -> $PREFIX/bin"
    mkdir -p "$PREFIX/bin"
    local b
    for b in "${BINS[@]}"; do
        cat > "$PREFIX/bin/$b" <<WRAPPER
#!/bin/sh
# Generated by steam-machine system/input-remapper/install.sh -- do not edit.
PREFIX="$PREFIX"
export LD_LIBRARY_PATH="\$PREFIX/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export GI_TYPELIB_PATH="\$PREFIX/lib/girepository-1.0\${GI_TYPELIB_PATH:+:\$GI_TYPELIB_PATH}"
export XDG_DATA_DIRS="\$PREFIX/share:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "\$PREFIX/venv/bin/python" "\$PREFIX/src/bin/$b" "\$@"
WRAPPER
        chmod 755 "$PREFIX/bin/$b"
    done
    chown -R root:root "$PREFIX/bin"
}

# --- system-side files --------------------------------------------------------

render_unit() {
    cat <<UNIT
[Unit]
Description=input-remapper injection daemon
Documentation=file://$REPO_DIR/README.md
Requires=dbus.service
After=dbus.service

[Service]
Type=dbus
BusName=inputremapper.Control
# Deliberately the /opt path, not /usr/bin/input-remapper-service: /opt survives
# a SteamOS A/B update untouched, so the daemon still starts on the first boot
# after one even if steam-machine-input-remapper.service has not yet replaced
# the /usr/bin wrappers.
ExecStart=$PREFIX/bin/input-remapper-service

[Install]
WantedBy=multi-user.target
UNIT
}

# Copy $1 to $2 only if it differs, reporting whether it had to. Callers use the
# return value to decide whether a udev/dbus/systemd reload is needed at all --
# on a normal boot nothing has changed and none of them run.
sync_file() {
    local src="$1" dest="$2" mode="${3:-644}"
    cmp -s "$src" "$dest" 2>/dev/null && return 1
    install -Dm"$mode" "$src" "$dest"
    return 0
}

# The /usr half. Checked before unlocking so the common case (nothing missing)
# never touches steamos-readonly or takes the repo-wide rootfs lock.
usr_files_ok() {
    local b
    for b in "${BINS[@]}"; do
        cmp -s "$PREFIX/bin/$b" "/usr/bin/$b" || return 1
    done
    [[ "$(readlink -f "$USR_DATA_LINK" 2>/dev/null)" == "$(readlink -f "$DATA_DIR")" ]] || return 1
    cmp -s "$SRC_DIR/data/input-remapper.policy" "$POLKIT_DEST" || return 1
    return 0
}

ensure_usr_files() {
    usr_files_ok && return 1

    trap relock_rootfs EXIT
    unlock_rootfs
    local b
    for b in "${BINS[@]}"; do
        cmp -s "$PREFIX/bin/$b" "/usr/bin/$b" && continue
        install -Dm755 "$PREFIX/bin/$b" "/usr/bin/$b"
        warn "restored /usr/bin/$b"
    done
    if [[ "$(readlink -f "$USR_DATA_LINK" 2>/dev/null)" != "$(readlink -f "$DATA_DIR")" ]]; then
        rm -rf "$USR_DATA_LINK"
        ln -sfn "$DATA_DIR" "$USR_DATA_LINK"
        warn "restored $USR_DATA_LINK -> $DATA_DIR"
    fi
    if ! cmp -s "$SRC_DIR/data/input-remapper.policy" "$POLKIT_DEST"; then
        install -Dm644 "$SRC_DIR/data/input-remapper.policy" "$POLKIT_DEST"
        warn "restored $POLKIT_DEST"
    fi
    relock_rootfs
    trap - EXIT
    return 0
}

# The /etc half. /etc is an overlayfs with its upper layer in /var, writable
# even when steamos-readonly is enabled, so this needs no unlock.
ensure_etc_files() {
    local changed=0 udev_changed=0 dbus_changed=0 r tmp

    sync_file "$KEEP_SRC" "$KEEP_DEST" && { warn "restored $KEEP_DEST"; changed=1; }
    sync_file "$SRC_DIR/data/inputremapper.Control.conf" "$DBUS_DEST" \
        && { warn "restored $DBUS_DEST"; dbus_changed=1; changed=1; }
    for r in "${UDEV_RULES[@]}"; do
        sync_file "$SRC_DIR/data/$r" "$UDEV_DEST_DIR/$r" \
            && { warn "restored $UDEV_DEST_DIR/$r"; udev_changed=1; }
    done

    tmp="$(mktemp)"
    render_unit > "$tmp"
    if ! cmp -s "$tmp" "$UNIT_DEST"; then
        install -Dm644 "$tmp" "$UNIT_DEST"
        warn "restored $UNIT_DEST"
        changed=1
    fi
    rm -f "$tmp"

    sync_file "$HEAL_UNIT_SRC" "$HEAL_UNIT_DEST" && { warn "restored $HEAL_UNIT_DEST"; changed=1; }

    [[ $udev_changed -eq 1 ]] && { udevadm control --reload-rules 2>/dev/null || warn "udevadm reload failed"; changed=1; }
    # Dropping the file in is not enough: the bus re-reads its policy only when
    # told to, so a freshly restored policy leaves the daemon dying with
    # "Request to own name refused by policy" -- which reads like a bad policy
    # file rather than a stale one.
    [[ $dbus_changed -eq 1 ]] && { systemctl reload dbus.service 2>/dev/null || warn "could not reload dbus"; }
    [[ $changed -eq 1 ]] && systemctl daemon-reload
    return 0
}

# Desktop entry, icon and the autoload autostart hook. All three go in /home
# rather than /usr and /etc/xdg/autostart, so they are the one part of this that
# a SteamOS update cannot touch.
install_user_files() {
    local apps="$TARGET_HOME/.local/share/applications"
    local icons="$TARGET_HOME/.local/share/icons/hicolor/scalable/apps"
    local autostart="$TARGET_HOME/.config/autostart"
    install -Dm644 "$SRC_DIR/data/input-remapper-gtk.desktop" "$apps/input-remapper-gtk.desktop"
    install -Dm644 "$SRC_DIR/data/input-remapper.svg" "$icons/input-remapper.svg"
    install -Dm644 "$SRC_DIR/data/input-remapper-autoload.desktop" "$autostart/input-remapper-autoload.desktop"
    chown -R "$TARGET_USER:$TARGET_USER" "$apps" "$icons" "$autostart" 2>/dev/null || true
    log "installed desktop entry, icon and autoload autostart under $TARGET_HOME"
}

# --- health -------------------------------------------------------------------

venv_healthy() {
    [[ -x "$VENV_DIR/bin/python" ]] || return 1
    [[ -f "$PY_MARKER" && "$(cat "$PY_MARKER")" == "$(py_minor)" ]] || return 1
    LD_LIBRARY_PATH="$PREFIX/lib" \
    GI_TYPELIB_PATH="$PREFIX/lib/girepository-1.0" \
    XDG_DATA_DIRS="$PREFIX/share:/usr/share" \
        "$VENV_DIR/bin/python" -c 'import inputremapper.daemon, inputremapper.gui.user_interface' \
        >/dev/null 2>&1
}

# --- top level ----------------------------------------------------------------

do_install() {
    need_root
    command -v git >/dev/null || die "git is required"

    local src; src="$(findmnt -no SOURCE /opt 2>/dev/null || true)"
    [[ "$src" == *"/.steamos/offload/opt"* ]] \
        || warn "/opt is '$src', not the expected SteamOS offload mount -- this install may not survive an OS update"

    mkdir -p "$PREFIX"
    fetch_src
    install_gtksourceview
    build_venv
    install_prefix_data
    write_wrappers
    venv_healthy || die "the built venv cannot import input-remapper -- refusing to install it"

    ensure_etc_files
    ensure_usr_files >/dev/null || true
    install_user_files

    systemctl enable steam-machine-input-remapper.service >/dev/null 2>&1 \
        || warn "could not enable steam-machine-input-remapper.service"
    systemctl enable --now input-remapper.service >/dev/null 2>&1 \
        || warn "could not enable input-remapper.service"

    log "done"
    echo
    do_status
}

do_boot() {
    need_root --boot

    # A python minor bump in a SteamOS update leaves the venv pointing at a
    # site-packages tree that no longer exists. Symptom without this: the daemon
    # starts, fails to import evdev, and the GUI reports nothing at all.
    if [[ -d "$SRC_DIR" ]] && ! venv_healthy; then
        warn "venv is unhealthy (system python is now $(py_minor)) -- rebuilding"
        install_gtksourceview
        build_venv
        install_prefix_data
        write_wrappers
        venv_healthy || warn "rebuild did not fix it -- run $REPO_DIR/install.sh by hand"
    fi

    [[ -d "$SRC_DIR" ]] || { warn "$SRC_DIR is missing -- run $REPO_DIR/install.sh"; return 0; }

    ensure_etc_files
    ensure_usr_files >/dev/null || true
    return 0
}

do_status() {
    local ok
    printf '%-24s' "prefix:"
    [[ -d "$PREFIX" ]] && echo "$PREFIX" || echo "MISSING"

    printf '%-24s' "upstream ref:"
    if [[ -d "$SRC_DIR/.git" ]]; then
        printf '%s (%s)\n' "$(git -C "$SRC_DIR" describe --tags --always 2>/dev/null)" \
                           "$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null)"
    else
        echo "no checkout"
    fi

    printf '%-24s' "venv:"
    if venv_healthy; then
        echo "healthy (python $(cat "$PY_MARKER" 2>/dev/null))"
    elif [[ -x "$VENV_DIR/bin/python" ]]; then
        echo "BROKEN -- built for python $(cat "$PY_MARKER" 2>/dev/null || echo '?'), system is $(py_minor)"
    else
        echo "MISSING"
    fi

    printf '%-24s' "gtksourceview4:"
    [[ -f "$PREFIX/lib/girepository-1.0/GtkSource-4.typelib" ]] && echo "unpacked in prefix" || echo "MISSING"

    printf '%-24s' "/usr/bin wrappers:"
    ok=0; for b in "${BINS[@]}"; do cmp -s "$PREFIX/bin/$b" "/usr/bin/$b" || ok=1; done
    [[ $ok -eq 0 ]] && echo "all ${#BINS[@]} present" || echo "MISSING or stale (an OS update wiped /usr; run --boot)"

    printf '%-24s' "DATA_DIR link:"
    if [[ "$(readlink -f "$USR_DATA_LINK" 2>/dev/null)" == "$(readlink -f "$DATA_DIR")" ]]; then
        echo "$USR_DATA_LINK -> $DATA_DIR"
    else
        echo "MISSING -- the GUI cannot find its glade file"
    fi

    printf '%-24s' "polkit action:"
    [[ -f "$POLKIT_DEST" ]] && echo "installed" || echo "MISSING (pkexec falls back to a generic admin prompt)"
    printf '%-24s' "dbus policy:"
    [[ -f "$DBUS_DEST" ]] && echo "$DBUS_DEST" || echo "MISSING -- the daemon cannot own its system-bus name"
    printf '%-24s' "udev rules:"
    ok=0; for r in "${UDEV_RULES[@]}"; do [[ -f "$UDEV_DEST_DIR/$r" ]] || ok=1; done
    [[ $ok -eq 0 ]] && echo "both installed" || echo "MISSING -- no hotplug autoload"
    printf '%-24s' "A/B update keep:"
    [[ -f "$KEEP_DEST" ]] && echo "installed" || echo "MISSING (dbus policy and udev rules lost on next update)"

    printf '%-24s' "daemon unit:"
    systemctl is-enabled input-remapper.service 2>/dev/null || echo "not installed"
    printf '%-24s' "daemon state:"
    systemctl is-active input-remapper.service 2>/dev/null || true
    printf '%-24s' "self-heal unit:"
    systemctl is-enabled steam-machine-input-remapper.service 2>/dev/null || echo "not installed"

    printf '%-24s' "/dev/uinput for deck:"
    getfacl -p /dev/uinput 2>/dev/null | grep -q "^user:$TARGET_USER:rw" && echo "rw (uaccess ACL)" || echo "NO ACCESS"
    printf '%-24s' "remappable devices:"
    if venv_healthy; then
        "$VENV_DIR/bin/python" -c 'import evdev; print(len(evdev.list_devices()), "readable by this user")' 2>/dev/null \
            || echo "could not query"
    else
        echo "n/a"
    fi

    printf '%-24s' "presets:"
    local p="$TARGET_HOME/.config/input-remapper-2/presets"
    [[ -d "$p" ]] && echo "$(find "$p" -name '*.json' 2>/dev/null | wc -l) in $p" || echo "none yet"
}

do_uninstall() {
    need_root --uninstall
    systemctl disable --now input-remapper.service >/dev/null 2>&1 || true
    systemctl disable --now steam-machine-input-remapper.service >/dev/null 2>&1 || true

    rm -f "$UNIT_DEST" "$HEAL_UNIT_DEST" "$KEEP_DEST" "$DBUS_DEST"
    local r; for r in "${UDEV_RULES[@]}"; do rm -f "$UDEV_DEST_DIR/$r"; done
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true

    trap relock_rootfs EXIT
    unlock_rootfs
    local b; for b in "${BINS[@]}"; do rm -f "/usr/bin/$b"; done
    rm -f "$POLKIT_DEST"
    [[ -L "$USR_DATA_LINK" ]] && rm -f "$USR_DATA_LINK"
    relock_rootfs
    trap - EXIT

    rm -f "$TARGET_HOME/.local/share/applications/input-remapper-gtk.desktop" \
          "$TARGET_HOME/.local/share/icons/hicolor/scalable/apps/input-remapper.svg" \
          "$TARGET_HOME/.config/autostart/input-remapper-autoload.desktop"
    rm -rf "$PREFIX"
    warn "presets in $TARGET_HOME/.config/input-remapper-2 were left alone"
    warn "the package cache in $CACHE_DIR was left alone"
    log "uninstalled"
}

case "${1:-}" in
    ""|--install) do_install ;;
    --boot)       do_boot ;;
    --status)     do_status ;;
    --uninstall)  do_uninstall ;;
    *) die "unknown option: $1" ;;
esac
