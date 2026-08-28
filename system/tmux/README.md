# tmux sessions that survive an SSH disconnect

**Symptom:** SSH in from a phone, start tmux, work, let the phone screen sleep. Reconnect five minutes later and `tmux ls` says `no server running on /tmp/tmux-1000/default`. The sessions were not detached — they no longer exist, along with whatever was running in them.

**Cause:** SteamOS ships this, from the `jupiter-legacy-support` package:

```
/etc/systemd/logind.conf.d/killuserprocesses.conf
[Login]
KillUserProcesses=True
```

With that set, logind kills everything in a login's `session-N.scope` the moment the session ends. A tmux server started by an SSH shell is a child of that shell and lands in exactly that scope:

```
$ cut -d: -f3 /proc/$(pgrep -u deck tmux | tail -1)/cgroup
/user.slice/user-1000.slice/session-3.scope
```

Phone SSH clients drop their TCP connection when the screen sleeps, so this fires on essentially every reconnect. It has nothing to do with tmux configuration, and `detach` versus a dropped connection makes no difference — the kill is by cgroup, not by tty.

## Fix

Start the server as a unit of `user@1000.service` instead, where it sits in `app.slice` and no session scope owns it:

```
/user.slice/user-1000.slice/user@1000.service/app.slice/steam-machine-tmux.service
```

Three pieces:

| Piece | Path | Why |
| --- | --- | --- |
| user unit | `~/.config/systemd/user/steam-machine-tmux.service` → repo | starts the server outside any session scope |
| shell wrapper | `bashrc.d/tmux.sh`, sourced from `~/.bashrc` | starts that unit on demand, so `tmux` still just works |
| linger | `/var/lib/systemd/linger/deck` | keeps `user@1000.service` up when no session is logged in |

```sh
./install.sh            # install all three
./install.sh --status   # includes the running server's cgroup and a verdict
```

## The part the installer cannot do for you

**An already-running server keeps its old cgroup forever.** tmux clients attach to whichever server owns the socket; a second `tmux` does not start a second server. So installing this while a session-scoped server is running changes nothing until that server is killed once:

```sh
tmux kill-server && tmux     # from outside tmux, when nothing important is running
```

`install.sh --status` prints the current server's cgroup and says which case you are in, so this is visible rather than something to remember.

## Why the unit is not enabled

`WantedBy=default.target` is present in the unit but the unit is deliberately left disabled, and `install.sh` never enables it.

The Plasma session pushes `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY` and `DBUS_SESSION_BUS_ADDRESS` into the user manager environment when it starts (`systemctl --user show-environment`). A server started on demand — after login, by the shell wrapper — inherits all of it, which is what keeps `SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A` working from inside a tmux pane. Verified: `env` inside a service-started session shows `DISPLAY=:0` and `WAYLAND_DISPLAY=wayland-0`.

Enabled, the unit would start at boot *before* Plasma sets any of that, and the server would keep that empty environment for its entire lifetime — every askpass dialog in every future pane failing with a bare "a password is required", days after the change that caused it.

## Persistence

Nothing here is in `/etc` or `/usr`, so there is no `--boot` self-heal and no `atomic-update.conf.d` entry:

- unit and shell snippet: `/home` — `nvme0n1p8`, its own partition
- linger flag: `/var/lib/systemd/linger/deck` — `nvme0n1p6`, its own partition

A SteamOS A/B update replaces the rootfs and wipes non-allowlisted `/etc`; it touches neither of those partitions. Confirmed with `findmnt -T /home /var`.

## Notes

- **`ssh machine tmux` bypasses this.** A non-interactive SSH command does not read `~/.bashrc`, so the wrapper is not in scope and a fresh server would be started in the session scope again. Use an interactive login, or `ssh -t machine 'systemctl --user start steam-machine-tmux.service; tmux attach'`.
- **Bare `tmux` now attaches** if any session exists, rather than creating another one — the reconnect case is the common one here. `tmux new` still creates explicitly.
- **`SSH_AUTH_SOCK` inside a long-lived server goes stale**, pointing at the socket of whichever connection was around when a pane was created. That is normal tmux behaviour, not caused by this change; tmux's default `update-environment` refreshes it for *new* windows on attach.
- **Valve set `KillUserProcesses=True` for a reason** — cleaning up after a Deck session. This subsystem does not turn it off; it moves one server out of its way. The blunter fix, `KillExcludeUsers=deck`, would disable that cleanup machine-wide for the only real user, and lives in `/etc` where it needs a keep entry to survive an update.
