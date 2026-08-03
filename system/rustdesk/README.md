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
