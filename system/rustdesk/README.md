# RustDesk — LAN-only unattended remote desktop

Graphical remote access to Desktop Mode, reachable by IP from this LAN only.

## Read this first: "LAN only" is not a RustDesk setting

**RustDesk has no supported way to keep direct-IP access while stopping the
client contacting its public rendezvous server.** This is not an oversight in
the config here; it is how the client is built:

- `Config::get_rendezvous_servers()` falls back to a hardcoded
  `["rs-ny.rustdesk.com"]`. Setting `custom-rendezvous-server` *redirects* the
  registration loop, it does not disable it.
- The only kill switch is `stop-service = "Y"` — and `direct_server()` checks
  the same flag, so it takes the direct listener down with it. It also runs
  `systemctl disable rustdesk` on the next start.
- `is_outgoing_only()` would work but reads `HARD_SETTINGS`, which is only
  populated from a `custom.txt` that is **ed25519-signed against RustDesk's own
  public key**. Not forgeable outside a Pro custom client.

So this machine still registers with RustDesk and holds an ID. What makes it
LAN-only in practice is two layers of inbound control:

1. **`whitelist`** in `RustDesk2.toml` — enforced in `check_whitelist()` from
   `on_open()`, which is the common entry point for *every* inbound connection
   including direct-IP ones, before authentication. Set to this LAN's subnets.
2. **firewalld rich rules** restricting `21118/tcp` to those same subnets.

Layer 2 matters more than it looks. The `public` zone on this machine allows
**`1024-65535/tcp` and `/udp` wholesale** — SteamOS ships it that way for Steam
— and the box holds a **globally routable IPv6 address**. Without the rich
rules, the direct-access port is reachable from anywhere the router will
forward, with only layer 1 in the way.

One deliberate leftover: leaving `custom-rendezvous-server` unset is *quieter*
than half-configuring it. `heartbeat_url()` falls back to `admin.rustdesk.com`,
which `is_public()` recognises and skips — whereas pointing it at a LAN address
switches the HTTP heartbeat **on**, aimed at `http://<that-ip>:21114`.

If you want the phone-home genuinely gone, block outbound to
`rs-ny.rustdesk.com` at the router. Cost of not doing so: one
`rendezvous mediator error` line every 18 s in the journal, and no effect
whatever on direct IP.

## Why /usr, on an immutable rootfs

`is_installed()` in `src/platform/linux.rs` is:

```rust
p.to_str().unwrap_or_default().starts_with("/usr")
    || p.to_str().unwrap_or_default().starts_with("/nix/store")
```

and `--password`, `--option`, `--config`, `--set-id` and `--deploy` all refuse
to run when it is false. Verified directly on this machine — running the binary
from a scratch directory and asking for `--option` returns *"Installation and
administrative privileges required!"*.

That rules out the obvious immutable-friendly locations. `/opt` and `/home`
both fail the check. It also **disqualifies the Flathub build outright**, which
installs to `/app` — on top of its sandbox having no `--socket=wayland`, no
`/dev/uinput`, and no systemd unit.

`/nix/store` would pass and `/nix` *is* an offload bind mount here that survives
updates — but that is an inference, not a tested path. This uses the pattern
already proven in `hardware/sensors/` for `it87` instead: cache the artefact
under `/home`, restore into `/usr` from `--boot`.

| Path | Survives A/B update? |
|---|---|
| `/home/deck/.cache/steam-machine-rustdesk/*.pkg.tar.zst` | yes |
| `/usr/bin/rustdesk`, `/usr/share/rustdesk` | **no** — restored by `--boot` |
| `/etc/systemd/system/rustdesk.service` | yes — default keep list |
| `/root/.config/rustdesk/` | yes — `/root` is an offload bind mount |

No `atomic-update.conf.d` entry is needed, which is unusual for this repo: the
only `/etc` file involved is the unit, and that is already on the default keep
list. The firewall rules are runtime-only by design — `/etc/firewalld` is not
keep-listed, and allowlisting the zone file would shadow every future upstream
version of it.

Installation is a plain tarball extract, not `pacman -U`. pacman would record
rustdesk in a database living outside the A/B image, so after an update it would
insist the package was installed while `/usr` had been wiped.

## Capture path

`get_display_server()` asks `loginctl show-session <seat0 active> -p Type`
**first**; `XDG_SESSION_TYPE` is only consulted if that returns empty, `tty` or
`unspecified`. On this machine seat0's active session reports **`wayland`** in
both Game Mode and Desktop Mode, so RustDesk takes the PipeWire/portal path
rather than X11.

That is worth knowing because the common advice — "RustDesk shows black under
gamescope because it grabs Xwayland" — does not obviously apply here. Desktop
Mode is the supported and tested configuration regardless: `kde.portal`
implements both `ScreenCast` and `RemoteDesktop`, whereas the gamescope portal
implements `ScreenCast` but **not** `RemoteDesktop`, so Game Mode input would
have to go via `/dev/uinput`. `deck` does hold a `uaccess` ACL on `/dev/uinput`,
so it is plausible — but untested, and not what this is set up for.

Confirmed on the live session bus while in Game Mode:

```
$ busctl --user introspect org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop
  org.freedesktop.portal.ScreenCast       present (version 5)
  org.freedesktop.portal.RemoteDesktop    ABSENT
```

The gamescope session also redirects portal lookup to its own directory
(`/usr/share/xdg-desktop-portal/gamescope-portals/`), which holds only
`gamescope.portal` and `holo.portal` — `kde.portal` is not a candidate there at
all. So this is structural, not a misconfiguration: in Game Mode there is no
`RemoteDesktop` implementation to bind to, and the journal shows `--server`
falling through to an X11 path it cannot use (`DISPLAY environment variable is
empty`). Desktop Mode sets `XDG_CURRENT_DESKTOP=KDE`, which selects
`kde-portals.conf` (`default=kde`) and brings `xdg-desktop-portal-kde` in with
both interfaces.

`is_x11()` is a `lazy_static`, evaluated once per `--server` process, so
switching session type needs a service restart, not just a reconnect.

## Desktop Mode only, and what it cost to find out

**The service does not start at boot and does not run in Game Mode.** It is started by a systemd *user* unit in the Plasma session and stopped when that session ends. This is not tidiness — left running in Game Mode it is one of the most expensive processes on the machine.

### What it does when it cannot find a session

The section above establishes that Game Mode has no `RemoteDesktop` portal, so `--server` falls through to an X11 path with no `DISPLAY`. RustDesk does not treat that as fatal and does not back off. It re-runs its session probe forever:

```sh
sh -c "ps -u 1000 -f | grep -E 'Xwayland' | grep -v 'grep' | tail -1 \
       | awk '{print \$2}' | xargs -I__ cat /proc/__/environ 2>/dev/null \
       | tr '\0' '\n' | grep '^WAYLAND_DISPLAY=' | tail -1 | sed 's/WAYLAND_DISPLAY=//g'"
```

Eight processes per iteration, roughly 65 iterations a second. Measured on 2026-08-14 with a game running:

| | |
|---|---|
| fork rate | **520/s** (275,384 forks in 529 s of uptime, from `/proc/stat`) |
| CPU | **621 s in 778 s of uptime** — 80% of a core, permanently |
| per-iteration cost | a full `/proc` walk, under the task-list lock, while the game holds thousands of threads |

Two details make this worse than the raw numbers suggest. `ps -u 1000 -f` reads every process in `/proc`, so the cost *scales with what else is running* — it is most expensive exactly when a game is loaded. And the work is invisible in the obvious places: `top` shows `rustdesk` at ~0% because no single child lives long enough to accumulate, and `ps` sampling never catches the children at all. The way to see it is `cminflt` deltas from `/proc/<pid>/stat`, which count faults charged back by *reaped* children:

```
$ # 6-second delta, per process
3416  rustdesk   cminflt+827302  cutime+345  cstime+192
```

`systemctl show rustdesk -p CPUUsageNSec` tells the same story in one line, and is the check worth remembering.

### How the gate works

| piece | where | role |
|---|---|---|
| `rustdesk-desktop-mode.service` | `~/.config/systemd/user/` | `WantedBy=plasma-workspace.target` — starts and stops the system unit |
| `60-steam-machine-rustdesk.rules` | `/etc/polkit-1/rules.d/` | lets `deck` do that without an auth prompt |
| `bin/rustdesk-in-desktop-mode` | this repo | the unit's `ExecCondition=`, a backstop against a manual start |

`plasma-workspace.target` is the discriminator. It is `static` and only a Plasma session pulls it in; Game Mode reaches `graphical-session.target` and `gamescope-session.target` and never touches it. So the gate is event-driven — no timer, no poll, nothing that has to notice a mode switch. `PartOf=` is what makes the stop happen on the way out.

Note what is *not* used: `loginctl show-session … -p Type` answers `wayland` in both modes and is useless here. The `Desktop` property does discriminate (`gamescope` vs `KDE`) and is what the `ExecCondition` script reads, but it is the backstop, not the trigger.

`rustdesk.service` has **no `[Install]` section** on purpose. Leaving the unit merely disabled would let a stray `systemctl enable rustdesk` quietly restore the boot-time start; with no `[Install]`, that command fails loudly instead.

### Consequences worth knowing

- **`install.sh --boot` now runs on entry to Desktop Mode, not at boot**, because it is the unit's `ExecStartPre`. Everything it restores (`/usr/bin/rustdesk`, `/usr/share/rustdesk`, the runtime firewall rules) is needed only when the service is about to run, so this is the correct moment — and a boot into Game Mode now costs nothing at all, where before it cost a package extract after every OS update.
- **The first Desktop Mode entry after a SteamOS update is slower**, since that extract happens then. The user unit uses `systemctl --no-block` so it does not time out waiting.
- **The firewall rules are re-applied at that point too.** They are runtime-only by design (`/etc/firewalld` is not keep-listed), so they are absent between a reboot and the first Desktop Mode entry. That is correct: nothing is listening on 21118 in the meantime.

## The password cannot be written by hand

Stored in `RustDesk.toml` (not `RustDesk2.toml`) as:

```
"01" + base64( secretbox( "00" + base64( SHA256(password ‖ salt) ) ) )
```

sealed with a key derived from `get_uuid()` — this machine's UID. Not portable,
not computable offline. `rustdesk --password` is the only route, and it needs
all of: `is_installed()` true, running as root, **and the `--server` child
alive**, because it works over the IPC socket. Hence a desktop session must be
active when you set it.

Note also that when run as root the command is wrapped in a `UserMainIpcScope`
guard that routes it to the *active desktop user's* IPC socket, and a 0.3 s sync
loop then pushes that up to root's config.

Because of that same sync loop, **edit `RustDesk2.toml` with the service
stopped**. Root's copy wins at `--server` startup and propagates down; editing
live means racing the loop.

## Usage

```bash
sudo ./install.sh              # download, verify, install, configure, start
sudo ./install.sh --password   # then this, with a desktop session on the TV
./install.sh --status
```

Connect from another machine on this LAN **by IP, not by ID**:

```
192.168.0.9:21118
```

The client takes the direct path with no rendezvous server involved whenever the
peer string parses as an IP — `Client::_start()` returns a plain
`connect_tcp_local()` immediately and never calls `get_rendezvous_server()`.

Switch to Desktop Mode before connecting. Game Mode is not what this is
configured for.

## Turning it on and off

**Normally you do not.** Switching to Desktop Mode starts it; leaving Desktop Mode stops it. That is the whole interface, and it is the one the gate above implements.

To override by hand:

```bash
sudo systemctl start rustdesk            # skipped with a "condition failed" note
                                         # if you are in Game Mode
sudo systemctl stop rustdesk             # stops it inside a Desktop session

./install.sh --status                    # unit state, gate, polkit rule, current
                                         # mode, config, firewall, listener
```

To turn the whole thing off for good, remove the gate rather than the service — the service has no `[Install]` section, so `systemctl disable rustdesk` has nothing to disable and `enable` fails:

```bash
systemctl --user disable rustdesk-desktop-mode.service   # as deck, no sudo
sudo systemctl stop rustdesk
```

Nothing is uninstalled either way. The binary, the config, the units and the cached package all stay put, so re-enabling is instant and needs no re-provisioning — `--password` in particular does not need doing again.

**Both states survive a SteamOS A/B update.** The user unit and its `.wants` symlink live under `/home`, which an A/B update does not touch at all, and "off" is simply the absence of that symlink. The polkit rule is in `/etc/polkit-1/rules.d`, which is *not* on the keep list — `atomic-update.conf.d/steam-machine-rustdesk.conf` names it, and `--boot` restores it. Losing it is the one failure that is hard to read: the service just never starts in Desktop Mode, and `systemctl status rustdesk` reports a healthy inactive unit with nothing wrong in its journal, because the refusal happens in the *user* manager.

**Any `start` re-applies the firewall rules**, because it runs the unit's `ExecStartPre=install.sh --boot`, which restores `/usr/bin/rustdesk` and calls `apply_firewall`. This matters because those rich rules are deliberately runtime-only, not `--permanent` (`/etc/firewalld` is not keep-listed) — so they do not survive a reboot on their own, and the service starting is what puts them back.

The corollary: **`stop` does not remove the rules** — only `--uninstall` does. That is harmless, since a rule restricting a port nothing is listening on costs nothing, but it does mean `firewall-cmd --list-rich-rules` still showing 21118 is not evidence the service is running. Check the unit, not the firewall.

Two traps, both covered in more detail above:

- **Do not use `stop-service = "Y"` as the off switch.** It is not a "pause the rendezvous registration" flag — `direct_server()` reads the same value, so it takes the direct-IP listener down with it, and it runs `systemctl disable rustdesk` on the next start. Use `systemctl` and leave the config alone.
- **Stop the service before editing `RustDesk2.toml`.** Root's copy wins at `--server` startup and propagates downward, so editing it live is racing the sync loop.

## Gotchas worth remembering

- **"Unattended" is not fully unattended on the first connection.** The KDE
  portal gates `ScreenCast`/`RemoteDesktop` behind an on-screen consent dialog.
  RustDesk requests a `persist_mode` restore token so later sessions should be
  silent, but the **first** one needs someone to click Allow on the TV. Until
  that has been granted once, a purely remote connect can hang with no picture
  and no obvious error. Untested here — worth doing deliberately while someone
  is in the room rather than discovering it remotely.
- `direct-server` must be exactly `"Y"`. `option2bool()` special-cases it, so
  `"true"`, `"1"` and `"yes"` all evaluate **false**.
- Never put `0.0.0.0` in `whitelist` — it is an explicit "disable the
  whitelist" bypass, not an address.
- LAN discovery (`start_lan_listening()`) also requires `is_installed()`, so a
  wrongly-placed install silently drops out of the "Discovered" peer list even
  when direct IP works.
- The whitelist and firewall subnets are derived from the live interface at
  install time and written only to `/root`. They are deliberately not in this
  repo — it is public, and the IPv6 prefix is a real routable address.
