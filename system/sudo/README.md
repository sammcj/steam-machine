# sudo password caching

```
./install.sh              install the drop-in, keep entry and boot unit
./install.sh --boot       restore what a SteamOS update dropped (run by a unit at every boot)
./install.sh --status     report state, change nothing
./install.sh --uninstall
```

## The symptom

Every `sudo` re-prompts, no matter how recently the password was entered — and because most of the shells on this machine have no terminal, each re-prompt is a **ksshaskpass dialog on the TV**. A three-command sequence means three trips to the TV.

## Why the cache never hit

sudo's default `timestamp_type` is `tty`: the credential record in `/run/sudo/ts` is keyed on the controlling terminal. That is a sensible default on a shared machine — authenticating in one terminal should not silently authorise another.

The catch is what happens when there is no terminal at all. Game Mode, an agent shell, a script, a systemd unit: none have a tty to key on, so sudo falls back to keying the record on the **parent process ID**. Every new shell is a new ppid, so the record never matches anything. The five-minute `timestamp_timeout` was never the limiting factor — the record was being looked up under a key that could not repeat.

`timestamp_type=global` keys the record on the user instead. One record, shared by every shell `deck` owns.

```
Defaults:deck timestamp_type=global
Defaults:deck timestamp_timeout=15
```

Five minutes was also not enough to get through a single `install.sh` run, hence fifteen.

## What this costs

For the length of the timeout, **any** process running as `deck` can run `sudo` without a password, not just the shell that authenticated. That is a real widening, and on a multi-user machine it would be the wrong call.

Taken deliberately here because:

- single-user living-room console; `deck` is the only real account,
- the only remote access is sshd restricted to `deck` (see [system/ssh/](../ssh/README.md)),
- `deck` is already in `wheel` with `(ALL) ALL`, so anything that can run as `deck` for fifteen minutes with a password prompt on a TV nobody is watching was never much of a barrier,
- the alternative is a password dialog on the TV per command, which pushes towards worse habits than the setting does.

Scoped with `Defaults:deck` rather than a bare `Defaults`, so it is not a machine-wide change. `/run` is tmpfs, so the cache is still gone at every reboot.

## Why it needs a keep entry

`/etc/sudoers.d` is **not** on the SteamOS atomic-update keep list. `/etc/passwd`, `/etc/group` and `/etc/shadow` are — the drop-in directory is not. So the file is deleted by the next A/B update, silently, and the only symptom is that the prompts come back. Hence [`atomic-update.conf.d/`](atomic-update.conf.d/steam-machine-sudo.conf) naming the specific file, plus `--boot` reinstalling it from a unit at every boot.

The installed file is `/etc/sudoers.d/10-steam-machine` with **no extension**: sudo skips any file in that directory whose name contains a dot. The repo copy carries `.conf` for the editor's benefit and `install.sh` strips it. This is also what makes the install safe — the candidate is written as `.10-steam-machine.new`, which sudo ignores outright, then renamed into place atomically.

## Safety

A malformed file in `/etc/sudoers.d` breaks sudo for every user, on a machine whose only other route to root is that same sudo. So `install.sh`:

1. runs `visudo -cqf` on the repo copy and refuses to install it if it does not parse,
2. writes it under the dotted temp name sudo ignores, then renames,
3. re-runs `visudo -cq` over the **whole set** and restores the previous file (or removes it) if that fails.

`--status` reports whether the whole set parses.

## Reading the status output

`--status` reports the Defaults resolved for `deck` via `sudo -U deck -l`, not `sudo -V`. That distinction matters and cost a false negative during the install: `sudo -V` reports the settings for **whoever runs it**, and these are `Defaults:deck` entries, so `sudo -V` under root prints the unchanged compiled-in `tty` / 5 minutes and looks exactly like the drop-in having no effect. It is simply not addressed to root.

## Verified

```
timestamp_type (deck):    global
timestamp_timeout (deck): 15
parses:                   yes (whole set)
```

and behaviourally, `sudo -n true` succeeding from two separate shells with different ppids after a single authentication — which is the thing that was broken.
