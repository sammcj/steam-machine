# Sleep / keep-awake

Stops the machine suspending out from under a remote session.

## The problem

The machine suspends while being worked on over SSH. Confirmed from the journal:

```
Aug 02 20:20:59 steammachine systemd-logind[1608]: The system will suspend now!
Aug 02 20:20:59 steammachine systemd[1]: Starting System Suspend...
Aug 02 20:20:59 steammachine kernel: PM: suspend entry (deep)
```

**It is not systemd idle.** `logind.conf` sets no `IdleAction` (the only drop-ins
are `KillUserProcesses=True` and `HandlePowerKey=ignore`), so logind's own idle
machinery is inert. The request comes over D-Bus from Steam — the Deck UI's
*Settings → Power → Sleep after inactivity*. Steam has no idea an SSH session
exists, because an SSH session is not user activity as far as gamescope is
concerned.

That it goes **through logind** is what makes it fixable: logind refuses to
suspend while a `block` inhibitor on `sleep` is held.

## Why this needs root, and why the polkit rule exists

The obvious fix does not work from a remote shell:

```
$ systemd-inhibit --what=sleep --mode=block --who=ssh --why="remote session" -- sleep 2h
Failed to inhibit: Interactive authentication required.

$ busctl call org.freedesktop.login1 /org/freedesktop/login1 \
      org.freedesktop.login1.Manager CanSuspend
s "challenge"
```

systemd's shipped policy for `org.freedesktop.login1.inhibit-block-sleep` is
`allow_any=auth_admin_keep`, `allow_active=yes`, `allow_inactive=yes`. An SSH
session is neither *active* nor *inactive* to polkit — those describe sessions
attached to a local seat — so it falls through to `allow_any` and gets a
password prompt. With no TTY that prompt cannot be answered and the command
simply hangs.

(`--what=idle` alone *is* permitted, matching `inhibit-block-idle`'s
`allow_any=yes` upstream. It is also useless here, since `IdleAction` is unset.)

Two consequences, and this subsystem uses both:

- The **automatic daemon runs as root**, where systemd short-circuits polkit
  entirely (caller uid == logind's uid), so it never touches this rule.
- The **manual `keepawake` function runs as `deck`**, so it needs
  `60-steam-machine-inhibit.rules` to grant that one action.

## What gets installed

| Path | Survives A/B update? |
|---|---|
| `/etc/systemd/system/steam-machine-keepawake.service` | yes — default keep list |
| `/etc/systemd/system/steam-machine-sleep-inhibit.service` | yes — default keep list |
| `/etc/polkit-1/rules.d/60-steam-machine-inhibit.rules` | **only via** `atomic-update.conf.d` |
| `/etc/atomic-update.conf.d/steam-machine-sleep.conf` | yes — preserves itself |
| one `source` line in `~/.bashrc` | yes — `/home` is untouched |

The daemon runs straight out of this repo (`bin/keepawake-daemon`), which lives
under `/home` and so is never replaced by an OS update.

Note the asymmetry that makes the keep entry worth having: if the polkit rule is
lost, **the automatic path keeps working** (it is root) while the manual
`keepawake` command starts hanging on a password prompt again. The obvious
post-update smoke test passes while the thing you reach for by hand does not.

## How it works

Two units, deliberately:

- **`steam-machine-sleep-inhibit.service`** does nothing but
  `systemd-inhibit … -- sleep infinity`. It is never enabled, only started and
  stopped on demand.
- **`steam-machine-keepawake.service`** runs the daemon, which polls logind once
  a minute and starts/stops the unit above.

Splitting them means *systemd* owns the lifetime of the inhibiting process.
`systemd-inhibit` holds the lock for exactly as long as its child lives, and
systemd's default `KillMode=control-group` tears the whole cgroup down on stop.
A shell script juggling a background PID would orphan the `sleep` — and leak the
lock — if it were killed at the wrong moment. `ExecStopPost` releases the lock if
the daemon itself dies.

The daemon holds the lock while **any logind session has `Service=sshd`**, plus
a grace window (`KEEPAWAKE_WINDOW`, default 1800 s) after the last one ends.

### Why the window is 1800 s and not longer

It was 7200 s (2 h) until 2026-08-03. That was too long, and the cost was not
obvious from inside this subsystem: the journal showed only **two suspends in
three days**, because any day with remote work on it kept the machine awake
essentially permanently — the tail from one session had not expired before the
next one began. A machine that never suspends wastes more power than every
tunable in [system/power/](../../system/power/README.md) saves.

1800 s matches Steam's own `IdleSuspendACSeconds`, which is the timer that
actually fires the suspend this inhibitor blocks. A tail longer than the timer
it defers is just dead time. It still covers the case the window exists for: a
dropped Wi-Fi link or a closed laptop lid reconnecting a few minutes later.

### The dependency on ClientAliveInterval

Counting sessions rather than keystrokes is simple and matches the requirement,
but it has one sharp edge: **a session that never ends holds the machine awake
forever.** A laptop that closes its lid or drops off Wi-Fi leaves an sshd session
registered with logind indefinitely.

That is why `system/ssh/` sets `ClientAliveInterval 60` / `ClientAliveCountMax 5`.
Without it this subsystem pins the machine awake on the first abandoned session,
and the symptom looks like "the keepawake daemon is broken". The two are a pair.

## Usage

Automatic — nothing to run. Being SSH'd in is enough.

Manual, for a hold that outlives your session (long build, big download):

```bash
keepawake            # 2h, the default
keepawake 4h         # any systemd time span: 30m, 90min, 1h30m
keepawake forever    # no timeout
keepawake off        # release now
keepawake status     # what is holding sleep open, and why
```

`keepawake` uses `systemd-run --user` rather than a backgrounded process on
purpose: `KillUserProcesses=True` is set, so anything left in the session scope
is killed on logout — exactly the case a manual hold is for. Parking it in the
user manager escapes that. `loginctl enable-linger` is not needed because sddm
autologins `deck` into the Deck UI with `Relogin=true`, so the user manager is
always running.

## Checking

```bash
./install.sh --status          # everything, including live inhibitors and sessions
systemd-inhibit --list         # who=steam-machine-keepawake means it is armed
systemctl status steam-machine-sleep-inhibit.service
journalctl -u steam-machine-keepawake -f
```

To change the grace window, edit `Environment=KEEPAWAKE_WINDOW=` in
`systemd/steam-machine-keepawake.service` and re-run `./install.sh`.

### `--status` reports two windows, and the difference matters

```
grace window (config):  1800 seconds after the last SSH session
grace window (running): 7200 seconds
[warn] the running daemon still has the OLD window (7200 s, config says 1800 s)
```

The installer used to finish with `systemctl enable --now`, and `--now`
degrades to `start` — a **no-op on an already-active unit**. So editing the
window and re-running the installer wrote the new unit file, reloaded systemd,
reported success, and left the old value live in the running process. `--status`
read the window from the unit file, so it confirmed a change that had not
happened. Caught on 2026-08-03 on the 7200 → 1800 change.

Fixed two ways, because either alone is a single point of failure:

- `do_install` now `restart`s rather than `start`s. The lock drops for well under
  a second — the new process re-acquires on its first loop iteration, before the
  first poll sleep — and Steam's suspend needs 30 minutes of inactivity, so the
  gap cannot lose a race.
- `--status` reports the **running** window alongside the configured one and
  warns on drift. It reads the value from the `started (window=Ns)` line the
  daemon logs at startup, filtered to the current `MainPID`. That is the only
  source that reflects the process rather than the file: `systemctl show -p
  Environment` re-reads the unit after a `daemon-reload` and would tell the same
  lie.

The general trap is worth remembering for any unit in this repo that carries
config in `Environment=`: `daemon-reload` makes systemd re-read the file, it does
not make a running process re-read anything.

## Not done here

Steam's own sleep timer is left alone. Turning it off in *Settings → Power*
would also solve the problem, but it would solve it for every case — including
the console genuinely sitting idle on the TV all night, which is the behaviour
worth keeping. This subsystem suppresses sleep only while someone is actually
working on the machine.
