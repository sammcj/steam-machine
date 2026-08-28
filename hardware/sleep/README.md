# Sleep / keep-awake — REMOVED

This subsystem held a logind `block` inhibitor on `sleep` while any SSH session existed, so the machine could not suspend out from under a remote shell. It was removed on 2026-08-18 because it did not delay suspends, it **cancelled** them — and it wedged the Steam client while doing so.

Only `install.sh --uninstall` and `--status` remain, to clean up a machine that still has the old files in `/etc`.

## What it broke

Reported as: "came back to the machine after a day, Steam's UI is blank, can't see the library". Restarting the Steam client fixed it. It had happened at least twice.

The blank library is Steam stuck **half-way through a suspend that never happened**.

```
2026-08-17 17:42:58  keepawake takes a block inhibitor on sleep (1 ssh session)
2026-08-17 18:13:56  steam: org.freedesktop.DBus.Error.AccessDenied:
                     Access denied due to active block inhibitor
2026-08-17 18:21:59  inhibitor released (grace expired)
   ... 24 hours awake, no further suspend attempt ...
2026-08-18 11:44:46  SteamUI: INFO:    SuspendResume: Received suspend request
2026-08-18 11:44:46  SteamUI: WARNING: SuspendResume: Ignoring suspend request
                     while a suspend operation is in progress: 1
```

That last pair is the whole fault. Steam sets an internal "suspend in progress" flag, tears its UI down ready for the suspend, then calls `org.freedesktop.login1.Manager.Suspend`. logind refuses. **Steam does not unwind.** The flag stays set, the UI stays torn down, and every later suspend request is ignored because a suspend is, as far as the client is concerned, still in progress. Nothing clears it but restarting the client.

Three observations that only fit this explanation, and rule out the alternatives:

- **The connection stays perfectly healthy.** `connection_log.txt` shows an unbroken hourly heartbeat straight through, and there is **no** `CCMInterface::OnSystemPowerStateSuspend` at 18:13:56 — every real suspend in the log has one, immediately followed by a matching `...Resume`. The refusal happens before the networking layer is ever told, which is why the client stays logged on while its UI is dead.
- **Library and store fail together.** Both are CEF web views; the rest of the client responds.
- **It is not a resume failure, because there was no resume.** `journalctl -b -k | grep -c "PM: suspend"` returned **0** against three days of uptime. The TV goes off via CEC and the machine never sleeps.

`steamui.txt` carries `SteamUI thread frame stalled for: 43646463 ms` entries and they are a **red herring** — they predate this, and the 2026-08-18 restart wrote no new one. They were the first explanation reached for and they were wrong.

## Why it could never have worked

Steam's idle-suspend is **one-shot**. It asks logind once per idle period and does not retry after a refusal — measured across three days: two refusals, two, and never an unprompted retry in between. A `block` inhibitor therefore does not postpone a suspend for the length of an SSH session, it removes that idle period's only suspend and wedges the client on the way past.

The original README argued the design was safe because the request "goes *through* logind, which is what makes it fixable". That is true of the refusal and false of the consequences. It also noted the journal showed "only two suspends in three days" and cut the grace window from two hours to thirty minutes in response — that was this bug, not the grace window, and shortening the window did nothing.

## What replaced it

Nothing. Steam may now suspend whenever it likes, including during an SSH session.

The exposure is smaller than it looks, and smaller than the old design assumed: because the timer is one-shot, a remote session is at risk at a single moment per idle period rather than continuously, and any local input re-arms it. `system/ssh/`'s `ClientAliveInterval 60` / `ClientAliveCountMax 5` still matter and are unaffected — they are what stops a dropped client leaving a session registered with logind for two hours of TCP timeout.

If a long unattended remote job genuinely needs protecting, take the lock by hand for the duration and drop it afterwards, rather than leaving a daemon to hold one:

```
sudo systemd-inhibit --what=sleep --mode=block --who=me --why="long job" -- <command>
```

That is a deliberate, bounded act with a visible owner in `systemd-inhibit --list`. Note it has exactly the same effect on Steam if a suspend is attempted while it is held — the client will need restarting. There is no configuration that avoids that; it is a Steam bug.

## Removing the leftovers

```
sudo ./install.sh --uninstall
     ./install.sh --status
```

Removes `/etc/systemd/system/steam-machine-{keepawake,sleep-inhibit}.service`, `/etc/polkit-1/rules.d/60-steam-machine-inhibit.rules` and `/etc/atomic-update.conf.d/steam-machine-sleep.conf`, and releases the lock if it is currently held.

`--status` also lists any `block` inhibitor on sleep from any source, since after all this that is the thing worth being able to see at a glance.
