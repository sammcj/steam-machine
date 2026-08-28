# Journal retention

Keeps a week of system logs instead of the ~two days SteamOS allows.

## The problem

An overnight fault is noticed the following evening. On 2026-08-17 the machine had not suspended once in two days — `journalctl -b -k | rg -c "PM: suspend"` returned **0** against an uptime of 2 days — and the Steam library had gone blank from a `SteamUI thread frame stalled for: 43646463 ms` (12 hours). Both are exactly the sort of thing you go looking for the next day.

`journalctl --list-boots` returned **one boot**. Not because the machine had only booted once (it had), but because there was no way to tell the difference — everything older than about two days was already gone.

The journal here is *not* the usual "logs are in RAM" case, and diagnosing it that way wastes the fix:

```
$ systemd-analyze cat-config systemd/journald.conf | rg "^# /|Storage|SystemMaxUse"
# /usr/lib/systemd/journald.conf.d/persistent-store.conf
Storage=persistent
# /usr/lib/systemd/journald.conf.d/system-max-use.conf
SystemMaxUse=50M
```

Storage is already persistent, `/var/log/journal` already exists, and `/var/log` is a bind onto `nvme0n1p8` at `/.steamos/offload/var/log` — the same 1.9 TB filesystem as `/home`, with 753 GB free, and not something an A/B update touches. The only problem is the **50 MB cap**. Measured growth on this machine is ~23 MB/day, so 50 MB buys about two days, and the files rotate every ~2.3 hours:

```
system@...-000659258590dec1.journal   Aug 16 20:24
system@...-0006592774ffed7e.journal   Aug 16 22:44
system@...-0006592968b99c6e.journal   Aug 17 00:58
```

## What this sets

One drop-in, `zz-steam-machine-journal.conf`:

| Setting | Value | Why |
|---|---|---|
| `Storage` | `persistent` | Explicit, not inherited — the file states the whole policy |
| `MaxRetentionSec` | `1week` | The actual ask: anything older than a week goes |
| `SystemMaxUse` | `512M` | Backstop only; a week is ~160 MB at current rates |
| `SystemMaxFileSize` | `32M` | Retention granularity — see below |

`MaxRetentionSec` can only delete **whole files** — a file is dropped when its *newest* entry is older than the limit. Left unset, `SystemMaxFileSize` defaults to 1/8 of `SystemMaxUse`, which would be 64 MB, or ~3 days per file, so a 1-week policy would in practice keep up to ~10 days. At 32 MB a file spans ~1.4 days and the week is honoured to within about that.

## The filename is the whole trick

systemd sorts drop-ins by **filename**, lexicographically, across *all* the directories they live in, and the file sorted last wins. The `/etc`-beats-`/usr` rule only applies between files with the *same* name.

Valve's are `persistent-store.conf` and `system-max-use.conf`. A conventional `99-` prefix would therefore **lose** — `9` (0x39) sorts before `p` (0x70) — and the drop-in would be silently overridden by the exact setting it exists to replace. There is no error and no log line; the only symptom is that retention never changes.

`zz-` sorts after both. `install.sh --status` reads the *merged* config back with `systemd-analyze cat-config` and names the file each value came from, and warns if `MaxRetentionSec` is winning from anywhere other than ours — checking our own file would confirm nothing.

## What gets installed

| Path | Survives A/B update? |
|---|---|
| `/etc/systemd/journald.conf.d/zz-steam-machine-journal.conf` | only via the keep entry below |
| `/etc/atomic-update.conf.d/steam-machine-journal.conf` | yes — `/etc/atomic-update.conf.d/*.conf` is on the default list, so it preserves itself |
| `/etc/systemd/system/steam-machine-journal.service` | yes — default keep list |

Verified 2026-08-17 against `/usr/lib/rauc/atomic-update-keep.conf`: there is **no** `/etc/systemd/journald.conf.d` entry and no `/etc/systemd/**` wildcard. The systemd entries on that list are specific to `/etc/systemd/system/*.{service,socket,mount}` and their drop-in and `.wants`/`.requires` directories. Without the keep entry the drop-in is dropped on the next update, journald falls back to 50 MB, and the failure conceals itself: the next person looking for evidence of an overnight fault finds none, which reads as "nothing was logged" rather than "the log was truncated".

The keep entry names the **specific file**, never the directory — an allowlisted path shadows all future upstream versions of it forever.

## Why the boot unit restarts journald

`systemd-journald` is one of the first processes on the system, running long before any unit of ours can be, and it reads its configuration exactly **once**, at start. It has no reload verb.

So on the boot after an update that ate the drop-in, restoring the file alone would leave journald running with the 50 MB cap until the *next* reboot — vacuuming the very window someone would later go looking for. `--boot` restores the file and restarts journald, but only when `ensure_etc_config` actually changed something. A restart is cheap and supported (the `/run/systemd/journal` sockets are socket-activated and outlive the daemon, so clients reconnect and nothing loses its stdout), but it can drop a handful of in-flight messages, and paying that on every boot to fix something that happens a few times a year is a bad trade.

## Usage

```
sudo ./install.sh              install drop-in, keep entry and boot unit
sudo ./install.sh --boot       restore anything an update dropped, then apply
     ./install.sh --status     state and *measured* retention, changes nothing
sudo ./install.sh --uninstall  back to Valve's defaults
```

`--status` reports the measured span (`oldest entry`, `actual span`, `boots retained`) rather than the configured one. The two differ whenever the size cap binds before the time cap, and the measured figure is the one that answers "will last night's logs still be here tomorrow evening".

`--install` and `--uninstall` need Desktop Mode: elevation on this box goes through `SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A`, which has nothing to draw in under Game Mode and fails with a bare `a password is required`.
