# sshd policy

Access policy and keepalives for the SSH server, plus the A/B-update entry that
stops SteamOS quietly discarding them.

## Why this exists

`/etc/ssh/sshd_config.d/10-steam-machine.conf` was already on the machine but
tracked nowhere and pinned by nothing. The SteamOS keep list
(`/usr/lib/rauc/atomic-update-keep.conf`) covers exactly two things under
`/etc/ssh`:

```
/etc/ssh/*_key
/etc/ssh/*_key.pub
```

Host keys, and nothing else. The server *configuration* is not on the list, so
the next A/B update would have deleted the drop-in and reverted sshd to stock
Arch defaults:

| Setting | After an update, without the keep entry |
|---|---|
| `AllowUsers deck` | gone — every account on the box may log in |
| `PermitRootLogin no` | gone — falls back to `prohibit-password` |
| `ClientAliveInterval 60` | gone — back to `0`, dead sessions never reaped |

The first two are a silent loosening of access policy. Nothing breaks, nothing
is logged; the machine simply becomes less locked down than you think it is.

## ClientAliveInterval

`ClientAliveInterval 60` / `ClientAliveCountMax 5` — five minutes of unanswered
keepalives before a session is torn down. Both default to off.

This is not cosmetic. `hardware/sleep/` holds a logind sleep inhibitor for as
long as *any* sshd session exists, so a session whose client vanished — lid
closed, Wi-Fi dropped, VPN flapped — would keep the machine awake indefinitely,
and the fault would present as "the keepawake daemon is broken" rather than
"there is a zombie session". These settings are what bound that.

Five minutes is deliberately tolerant: it rides out a brief Wi-Fi drop or a
router reboot without killing a live session, while still reaping a genuinely
dead one well inside keepawake's two-hour grace window. It also keeps NAT and
stateful-firewall mappings warm, which stops idle sessions being blackholed.

The trade-off is real: a client that suspends for longer than five minutes loses
its session. That is the correct outcome for the inhibitor. The right fix for
long-lived work is `tmux` on this end, not a longer timeout.

## What gets installed

| Path | Survives A/B update? |
|---|---|
| `/etc/ssh/sshd_config.d/10-steam-machine.conf` | **only via** `atomic-update.conf.d` |
| `/etc/atomic-update.conf.d/steam-machine-ssh.conf` | yes — preserves itself |
| `/etc/systemd/system/steam-machine-ssh.service` | yes — default keep list |

The keep entry names the one file, never `/etc/ssh/*` or the `sshd_config.d`
directory — an allowlisted path shadows all future upstream versions of it
forever, and `/etc/ssh` is very much a directory openssh and SteamOS both ship
into. `99-archlinux.conf` and the symlinked `20-systemd-userdb.conf` are
package-owned and are restored by the update itself.

## Lockout safety

sshd is the only remote way into this machine, so every path that touches its
config validates with `sshd -t` **before** anything is reloaded, and restores the
previous file if validation fails.

Reloads are `systemctl reload sshd`, never `restart`: a reload applies the new
config to new connections only and leaves existing sessions — including the one
running the install — untouched.

`PasswordAuthentication` is still `yes`. See the TODO in
`sshd_config.d/10-steam-machine.conf`; do not flip it to `no` until a key login
has been confirmed working from every client that needs to reach the box.

## Checking

```bash
./install.sh --status        # installed state plus effective settings via sshd -T
sudo sshd -T | grep -iE 'clientalive|allowusers|permitrootlogin'
```
