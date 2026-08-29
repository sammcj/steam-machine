# input-remapper on SteamOS

[input-remapper](https://github.com/sezanzeb/input-remapper) 2.2.1, installed into `/opt/input-remapper` and made to survive SteamOS A/B updates. Upstream has no Flatpak ([#664](https://github.com/sezanzeb/input-remapper/issues/664), [#924](https://github.com/sezanzeb/input-remapper/issues/924) still open) and no supported Steam Deck path ([discussion #587](https://github.com/sezanzeb/input-remapper/discussions/587)), so this is a hand-rolled install.

```
./install.sh              build and install
./install.sh --boot       restore what a SteamOS update dropped (run by a unit at every boot)
./install.sh --status     report state, change nothing
./install.sh --uninstall
```

## It does not need kernel headers

The README's `python3-dev` reads like a build-against-the-kernel requirement. It isn't. input-remapper has **no kernel module and no DKMS**: it reads `/dev/input/event*` and writes a virtual device through `/dev/uinput` — an in-tree module already loaded here — using `python-evdev`. The compiler is only needed if pip has to build `python-evdev` from source, which it would, because PyPI ships evdev sdist-only.

That build never happens here, because SteamOS already ships every component that would need compiling:

| Dependency | Source |
|---|---|
| `evdev` 1.9.0, `psutil`, `PyGObject`, `pycairo` | SteamOS `/usr/lib/python3.13/site-packages` |
| GTK 3, Gdk, Gst 1.0 typelibs | SteamOS |
| `dasbus`, `pydantic`, `packaging` | pip wheels into the venv |
| **gtksourceview4** | the one real gap — see below |

Nothing is compiled by `install.sh`. There is no `gcc`, no `make` and no `/usr/include/linux/input.h` on this machine, and none are needed.

`gtksourceview4` is the only system library input-remapper needs that SteamOS does not ship, and `gi.require_version("GtkSource", "4")` is a hard failure without it — it takes down the *daemon* as well as the GUI, not just the editor widget. Rather than `pacman -S` into a rootfs that gets replaced, `install.sh` fetches `gtksourceview4-4.8.4-2` from Valve's own Arch mirror against a pinned SHA-256 and unpacks four runtime files (the `.so`, the typelib, and the language-spec/style data) into the prefix. The wrappers point `LD_LIBRARY_PATH`, `GI_TYPELIB_PATH` and `XDG_DATA_DIRS` at them. 3.3 MB, no rootfs write, no pacman.

## Why /opt, and the five things that could not go there

Upstream installs with `python3 -m install --root /`, which writes to `/usr/bin`, `/usr/share`, `/usr/lib/systemd/system`, `/usr/lib/udev/rules.d` and `/etc/xdg/autostart`. [`install/module.py`](https://github.com/sezanzeb/input-remapper/blob/main/install/module.py) goes further and explicitly scores any site-packages path under `/home` at **-50**, on the grounds that udev's python does not import from there. Installed upstream's way this vanishes on the next OS update with no error at all — just a GUI that stops starting.

So the application lives in `/opt/input-remapper`, which is a SteamOS offload mount on the home partition (`findmnt /opt` → a source ending `[/.steamos/offload/opt]`; the device node itself moves between A/B slots, so `install.sh` matches on the subpath and never on the device): writable without unlocking the rootfs, and untouched by an A/B update. Same reasoning as [system/btop/](../btop/README.md).

Five things resolve by absolute path from outside our control and could not move:

| Path | Why it cannot live in /opt | Persistence |
|---|---|---|
| `/usr/bin/input-remapper-*` | `pkexec` resolves the GUI's root helper through `PATH` and refuses anything not owned by root; the polkit action's `exec.path` annotation names `/usr/bin` | reinstalled by `--boot` |
| `/usr/share/input-remapper` | `installation_info.py` hardcodes `DATA_DIR = "/usr/share/input-remapper"` — installed as a **symlink** into the prefix, so it costs one inode | reinstalled by `--boot` |
| `/usr/share/polkit-1/actions/input-remapper.policy` | polkit reads action files from `/usr` only; there is no `/etc` equivalent | reinstalled by `--boot` |
| `/etc/dbus-1/system.d/inputremapper.Control.conf` | `daemon.py` uses dasbus `SystemMessageBus` — there is no session-bus option in the code | keep-listed + `--boot` |
| `/etc/udev/rules.d/{69,99}-input-remapper*.rules` | hotplug autoload is a udev rule calling `/bin/input-remapper-control` | keep-listed + `--boot` |

`/etc/systemd/system/*.service` is already on the default keep list, so both units are safe without an entry. `/etc/udev/rules.d` and `/etc/dbus-1/system.d` are not, hence [`atomic-update.conf.d/`](atomic-update.conf.d/steam-machine-input-remapper.conf) — naming the specific files, never the directories.

The desktop entry, the icon and the autoload autostart hook go to `~/.local/share` and `~/.config/autostart` instead of `/usr/share` and `/etc/xdg/autostart`. Those are the one part of this a SteamOS update cannot reach.

### The daemon unit points at /opt on purpose

`ExecStart=/opt/input-remapper/bin/input-remapper-service`, not the `/usr/bin` wrapper. On the first boot after an A/B update `/usr` is fresh and the wrappers are gone; the self-heal unit is ordered `Before=input-remapper.service`, but pointing the daemon at the path that never disappears means injection still works even if the self-heal fails. Only the GUI needs `/usr/bin`.

## The venv is `--system-site-packages`, which is the fragile part

The venv borrows `evdev`, `PyGObject`, `pycairo` and `psutil` from `/usr/lib/python3.13/site-packages`. That is what makes a zero-compile install possible, and it is also the one thing that can break without touching anything in this directory: **if a SteamOS update moves the system python to 3.14, the venv points at a site-packages tree that no longer exists.** The daemon would still start, fail to import evdev, and the GUI would report nothing useful.

`install.sh` writes the python minor version to `/opt/input-remapper/.python-version` and `--boot` compares it against the live `/usr/bin/python3` before anything else, rebuilding the venv if they differ. `--status` reports the mismatch explicitly rather than just saying "broken".

Related trap: **`python3` on this box is Homebrew's 3.14.7**, first on `deck`'s `PATH`, and it has none of the system site-packages — `import gi` fails under `python3` and succeeds under `python3.13`. Every python invocation in `install.sh` is the absolute `/usr/bin/python3` for that reason.

## Permissions: root is required, but not for device access

SteamOS has already done the permissions work. logind's `uaccess` ACLs give `deck` rw on `/dev/uinput` and on every seat-attached event device:

```
crw-rw----+ 1 root root  10, 223 /dev/uinput     → user:deck:rw-
crw-rw----+ 1 root input 13,  64 /dev/input/event0 → user:deck:rw-
```

So injection does not need root here, and `deck` does not need to be added to the `input` group. Upstream 2.2.1 even has a bypass for exactly this ([#1327](https://github.com/sezanzeb/input-remapper/pull/1327)) — but its check is `all(os.access(p, os.R_OK) for p in glob("/dev/input/event*"))`, and 17 of this machine's 31 event nodes are *not* deck-readable (HD-Audio jack detect, `Video Bus`, `PC Speaker`, `steamos-manager`). None of them are remappable, but the `all()` fails anyway, so the GUI still goes through `pkexec`.

Running it entirely as a `systemd --user` service was considered and rejected: `input-remapper-reader-service` hard-refuses at `os.getuid() != 0`, `daemon.py` owns its name on the **system** bus with no session-bus option, and hotplug autoload is a system udev rule. All three would need patching upstream, on every version bump. Not worth it when the root daemon is three keep-listed files away.

## Gamescope and Steam Input

**Untested in Game Mode, and the GUI will not run there** — it is GTK3 and needs the Desktop session. The structural concern is real: input-remapper grabs the physical device and emits a virtual one, which is the same pattern behind Steam Input's duplicate-controller problems. If you remap a controller, expect to check whether Steam sees two.

For keyboards and mice (the `Logitech K400 Plus` here) that concern does not apply.

Presets live in `~/.config/input-remapper-2/presets/` — on `/home`, so they need no special handling.

## Verified

- `input-remapper 2.2.1`, `python-evdev 1.9.0`, daemon `active (running)`.
- `input-remapper-control --list-devices` as `deck` returns the K400 Plus, the Steam Controller puck, the 2.4G mouse and the Turtle Beach headset.
- Full GTK stack imports in a scrubbed environment (`env -i`): Gtk 3.0, GtkSource 4, Gst 1.0, and `get_data_path()` resolves `input-remapper.glade` and `style.css` through the `/usr/share` symlink.
- Self-heal exercised for real: deleting `/etc/dbus-1/system.d/inputremapper.Control.conf` and running `--boot` restored it, reloaded the bus and left everything else untouched — no rootfs unlock, because nothing in `/usr` was missing.

## One trap worth remembering

Dropping the dbus policy file into place is not enough. The bus re-reads its policy only when told to, so a freshly restored policy leaves the daemon dying with:

```
dasbus.error.DBusError: Request to own name refused by policy
```

which reads like a *bad* policy file rather than a stale one. `install.sh` reloads `dbus.service` whenever it writes that file, and only then.

## Pinning

`UPSTREAM_REF="2.2.1"` with `UPSTREAM_COMMIT="e9a87d13..."`. A tag is a movable ref, so the commit is verified after fetching — upstream retagging would fail the install rather than silently changing what gets installed. To bump, change both.

Do **not** move to PyPI `evdev` 2.0.0: input-remapper 2.1.1 was specifically a compatibility fix for `python-evdev` 1.9.0, and 2.0.0 compatibility is unverified. The system package is 1.9.0 and that is the version this is tested against.
