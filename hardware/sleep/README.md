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
a grace window (`KEEPAWAKE_WINDOW`, default 7200 s) after the last one ends.

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

## Not done here

Steam's own sleep timer is left alone. Turning it off in *Settings → Power*
would also solve the problem, but it would solve it for every case — including
the console genuinely sitting idle on the TV all night, which is the behaviour
worth keeping. This subsystem suppresses sleep only while someone is actually
working on the machine.
