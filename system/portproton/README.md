# PortProton default wine version

Keeps PortProton's default wine version pointed at the **newest installed GE-Proton** build, so a freshly downloaded GE-Proton becomes the default for new games without editing anything by hand.

```
./install.sh              install the user units and set the default now
./install.sh --update     set the default to the newest GE-Proton in dist
./install.sh --status     report current state
./install.sh --uninstall  remove the units, leave user.conf alone
```

Run as `deck`, **not** with sudo — everything here is per-user.

## Where the setting actually lives

PortProton reads its default wine version from `PW_WINE_USE`. Two files set it:

| file | sourced at | survives a PortProton update |
|---|---|---|
| `data/scripts/var:48` (`PW_WINE_USE="PROTON_LG"`) | before user config | no — shipped by PortProton, rewritten every update |
| `data/user.conf` | `start.sh:208`, after `var` | yes — user-owned, never touched |

So the override goes in `data/user.conf`:

```bash
export PW_WINE_USE="GE-PROTON11-3"
```

`PROTON_LG` and `WINE_LG` are aliases resolved at runtime to `PW_PROTON_LG_VER` / `PW_WINE_LG_VER` (Valve Proton and PortProton's own Wine build). A GE-Proton has no alias — it must be named by its exact directory name under `data/dist/`.

## Why it needs automation

Downloading a new GE-Proton only fetches the build. Nothing rewrites `PW_WINE_USE`, so `user.conf` keeps naming the old version indefinitely. Two triggers cover it:

- `portproton-default-wine.path` — watches `data/dist` and fires when a new build directory appears. Covers a download made while logged in.
- `portproton-default-wine.service` — also `WantedBy=default.target`, so a build that arrived while this session was not running is picked up at the next login.

Both are **systemd user units** in `~/.config/systemd/user`.

### Half-extracted builds

The path unit fires when the directory is *created*, which is the start of extraction, not the end. `--update` guards against writing a broken name two ways:

1. A candidate only counts if it has both `proton` and `files/bin/wineserver`.
2. It then waits until nothing under the directory has changed for 10 seconds (up to two minutes) before writing.

If it never settles, the run does nothing and the next trigger — or the next login — retries.

## Pinning

If a newer GE-Proton regresses something, pin the current one by adding a trailing comment in `user.conf`:

```bash
export PW_WINE_USE="GE-PROTON11-3"  # pinned
```

`--update` then leaves the line alone, and `--status` reports `[pinned]`. Remove the comment to resume tracking.

## Scope: new games only

A game that already exists has its own `.ppdb` file next to its `.exe`, carrying its own `PW_WINE_USE`. That file is sourced *after* `user.conf` (`functions_helper:2476`), so it wins — an existing game keeps the build it was created with. This is deliberate: a game that works should not silently move to an untested wine version. Change those per game in PortProton's settings dialog.

## Why there is no `--boot` and no keep entry

Nothing here touches `/etc` or `/usr`. The script (this repo), the units (`~/.config/systemd/user`) and `user.conf` (`~/PortProton`) all live in `/home`, which a SteamOS A/B update does not touch. Same reasoning as `system/shell` and `system/btop`.

PortProton itself is the Flatpak `ru.linux_gaming.PortProton`; `~/PortProton` is its data directory (a symlink target the Flatpak creates), not part of the Flatpak install, so a PortProton update does not disturb any of this either.
