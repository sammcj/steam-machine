# CoolerControl

Web-based temperature, fan and power monitoring, on port **11987** — from this
machine at [http://localhost:11987](http://localhost:11987), and from anywhere
on the home network at `http://<this machine>:11987`.

**Status: working.** Monitoring only, in the sense that it never touches the fan
curves — see [Deliberately read-only](#deliberately-read-only). The *API* is
read/write and password-protected; see [Network exposure](#network-exposure).

Builds on [hardware/sensors/](../sensors/README.md): CoolerControl reads hwmon,
so everything that setup exposed (IT8696E fan RPM and VRM temps, SATA SSD
temps) shows up here without further work.

## What is installed

Only `coolercontrold`. Since v4 the daemon embeds the entire web UI and serves
it itself, so the separate desktop app buys nothing on a machine whose only
display is a TV running Gamescope — and the web UI is reachable from a laptop
anyway, which the desktop app is not.

There is no packaged build for SteamOS. The upstream project publishes a
standalone x86_64 binary per release, which is what this uses: it links only
`libc`, `libm` and `libgcc_s`, so nothing else has to be installed.

| Path                                                 | Survives A/B updates?                        |
| ---------------------------------------------------- | -------------------------------------------- |
| `/home/deck/.local/lib/coolercontrol/coolercontrold`  | yes — `/home` is its own partition           |
| `/var/lib/coolercontrol/`                             | yes — `/var` is its own partition            |
| `/etc/systemd/system/coolercontrold.service`          | yes — on the default `/etc` keep list        |
| `/etc/coolercontrol/*`                                | **only via the keep entry below**            |
| `/etc/atomic-update.conf.d/steam-machine-coolercontrol.conf` | yes — keeps itself             |
| `~/.cache/steam-machine-coolercontrol/`               | yes — download cache                         |

Nothing lands in `/usr`, so unlike `it87` there is no module to rebuild. The
binary is root-owned despite living under `/home`: systemd runs it as root, and
a root-executed binary should not be user-writable.

### `/etc/coolercontrol` needs an explicit keep entry

Since SteamOS 3.6 only an allowlisted subset of `/etc` carries into a new A/B
image — see [SteamOS persistence](../../README.md#steamos-persistence). The
default list covers `/etc/systemd/system/*.service`, so the unit and its enable
symlink survive on their own. It does not cover `/etc/coolercontrol`, and
losing that directory is the one failure here that is more than cosmetic: the
daemon would come back with the upstream default `apply_on_boot = true` and
start reapplying saved profiles to the fans.

Both halves of the repo-wide pattern are used:

1. `atomic-update.conf.d/steam-machine-coolercontrol.conf`, installed to
   `/etc/atomic-update.conf.d/`.
2. `install.sh --boot`, wired in as the daemon's `ExecStartPre`. It reinstalls
   the keep entry if missing, regenerates the config if the whole directory
   went, and re-asserts the monitoring-only settings *before* the daemon can
   act on them. There is no `-` prefix on the `ExecStartPre`: if monitoring-only
   can't be guaranteed, not starting is the right outcome — that costs
   temperature graphs, not boot.

This is the one place in this repo that allowlists a wildcard rather than named
files. The usual rule exists because an allowlisted path shadows all future
upstream versions of it forever, which is a trap for a directory SteamOS also
ships into. Nothing ships `/etc/coolercontrol` — no pacman package owns it, the
daemon comes from a standalone binary — so there is no upstream version to
shadow, and naming files individually would instead mean silently losing any
new state file a future CoolerControl release adds.

`./install.sh --status` reports whether the keep entry is present and current.

## Usage

```bash
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh       # install + start
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh --lan # also listen on the LAN
./install.sh --status
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh --disable # stop, and don't start on boot
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh --enable  # undo --disable
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh --uninstall
```

`--disable` / `--enable` are thin wrappers over `systemctl disable --now` /
`enable --now`. Nothing is removed, so `--enable` brings it back exactly as it
was. The enable symlink lives under
`/etc/systemd/system/multi-user.target.wants/`, which is on the default keep
list, so a disabled daemon stays disabled across an OS update rather than
quietly coming back. `--status` shows which it currently is.

`--boot` also exists but is for the service's `ExecStartPre`, not for typing —
see [`/etc/coolercontrol` needs an explicit keep entry](#etccoolercontrol-needs-an-explicit-keep-entry).

`install.sh` is idempotent. The 37 MB binary is pinned by version *and* sha256
and cached under `~/.cache/` rather than committed; the checksum is what makes
that reproducible. To upgrade, bump `VERSION` and `SHA256` at the top of the
script and re-run.

Login is `CCAdmin` plus a password, set in the UI under Settings → Password.
The factory default is `coolAdmin`; it is **not** the default here, since the
UI is on the LAN.

The password hash lives in `/etc/coolercontrol/.passwd`. Deleting
`/etc/coolercontrol` — which is what an OS update does without the keep entry —
takes it with it, and what comes back is not the factory default either. If you
are ever locked out, stop the daemon and reset it:

```bash
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A systemctl stop coolercontrold
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A \
    /home/deck/.local/lib/coolercontrol/coolercontrold --reset-password
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A systemctl start coolercontrold
```

That restores `coolAdmin`. Set a real one again straight after.

## Deliberately read-only

`apply_on_boot = false` is set in `/etc/coolercontrol/config.toml`.

The board's fan curves stay under BIOS control, matching the rule in
[hardware/sensors/](../sensors/README.md#the-it87-driver): nothing here writes
`pwmN_enable`. CoolerControl is fully capable of taking over the fans — this
setting just stops it reapplying saved profiles on every start, so a stray
click in the UI can't quietly become permanent.

`install.sh` checks this after starting the daemon, and `--status` re-checks it
any time: all five `it8696` `pwmN_enable` must read `2` (automatic). A `1` means
something has taken manual control.

It is re-asserted on every daemon start by `--boot`, because the setting only
holds as long as `/etc/coolercontrol/config.toml` does — see
[above](#etccoolercontrol-needs-an-explicit-keep-entry).

`liquidctl_integration = false` as well. There is no liquidctl-supported
hardware in this build — the AIO is a plain PWM unit on an ITE header — and
disabling it avoids the Python dependency and the USB probing that come with it.

## Sensor labels are not the lm_sensors ones

CoolerControl reads `/sys/class/hwmon` directly. It does **not** use
libsensors, so `/etc/sensors.d/steam-machine.conf` — the labels and `ignore`
lines derived by correlation in [hardware/sensors/](../sensors/README.md#sensor-identification)
— has no effect here. Out of the box you get raw `temp1`…`temp6` and `fan1`…`fan5`,
including the three unconnected channels and the duplicate `gigabyte_wmi` chip.

Rename and hide them once in the UI (click a channel → pencil icon); it is
stored in `/etc/coolercontrol/config-ui.json` and persists. The mapping, from
the correlation table in the sensors README:

| `it8696`   | Is                                  |
| ---------- | ----------------------------------- |
| `temp2`    | board / chipset / M.2 area          |
| `temp3`    | CPU (matches `Tctl`)                |
| `temp5`    | VRM                                 |
| `fan1`     | AIO radiator fans (`pwm1`)          |
| `fan3`     | AIO pump (`pwm3`)                   |
| `fan5`     | case fan — **no PWM channel**, see below |
| `temp1`, `temp4`, `temp6`, `fan2`, `fan4` | unconnected — hide |

`gigabyte_wmi` is the same IT8696E read over ACPI-WMI; its `temp1`–`temp5` are
byte-identical to `it8696`'s. Hide the whole device so nothing double-counts.

## Proving which tach is which fan

Nothing in sysfs says which `fanN` is on which physical header — the driver
numbers registers, not connectors, and the labels above were originally a guess.
To re-derive them, drive one `pwmN` at a time and watch every tach. Set
`pwmN_enable` to `1` first (manual); put it back to `2` afterwards or the board
firmware never resumes its curve:

```bash
# Resolve by name, never by index. hwmon numbering is probe-order and shifts between boots -- hwmon4 was it87 when this was written and is drivetemp now, so the hardcoded path would have swept PWM on the wrong chip.
H=$(dirname "$(grep -lx it8696 /sys/class/hwmon/*/name)")
for p in 1 2 3 4 5; do echo 1 > $H/pwm${p}_enable; echo 60 > $H/pwm$p; done
echo 255 > $H/pwm1; sleep 8; grep . $H/fan*_input   # repeat per channel
for p in 1 2 3 4 5; do echo 2 > $H/pwm${p}_enable; done
```

**Do not sweep `pwm4`.** It is an unpopulated header, and the BIOS never
configures its automatic trip points. Writing `pwm4_enable = 1` is therefore a
one-way trip: `it87`'s `check_trip_points()` rejects the write back to `2` with
`EINVAL` ("Inconsistent trip points" in `dmesg`), and this survives a
`modprobe -r it87` because the inconsistency is in the chip registers, not the
driver's cache. Only a reboot — where the BIOS reinitialises the chip — restores
it. Harmless to cooling (nothing is plugged in) but `install.sh --status` will
flag the channel until then. `pwm2` behaves and can be put back.

Measured 2026-08-02, idle:

| tach   | 0% duty  | 24%  | 100% | driven by | reading |
| ------ | -------- | ---- | ---- | --------- | ------- |
| `fan1` | 0        | 482  | 1196 | `pwm1`    | stops dead → a fan |
| `fan3` | **1516** | 1912 | 2419 | `pwm3`    | responds but never stops → a pump |
| `fan5` | 1548     | 1544 | 1548 | *nothing* | 3-pin fan on a PWM-mode header — see below |
| `fan2` | 0        | 0    | 0    | —         | unpopulated header |

Two of the three fall out of this without touching the case. `fan1` is the only
channel that reaches a true 0 rpm, so it is a fan; holding `pwm3` at 0 for a
minute leaves `fan3` parked at 1516 rpm indefinitely, and a fan on a PWM header
cannot do that — only a pump has a floor it will not drop below while still
tracking duty. Radiator-vs-case for `fan1` needs one physical check: pulse
`pwm1` between 0 and 255 and feel the radiator and the rear grille. Confirmed
radiator.

Airflow by hand turned out to be a poor signal for `pwm3` — the pump's spin-down
takes longer than the ~5 s you can hold a hand there, and it moves no air. Trust
the 0%-floor test instead.

## The case fan: fixed, then stalling (resolved 2026-08-03)

The table above was measured while the CPU_OPT header was in **PWM mode** with what turned out to be a **3-pin (DC) fan** on it. A 3-pin fan ignores the PWM pin and sees a permanent 12 V, which is exactly the observed signature: ~1545 rpm regardless of duty, unresponsive to all five channels. The diagnosis in the original write-up was right, and the header was subsequently set to **Voltage/DC** in BIOS.

That made it controllable — and introduced a new failure. In DC mode the duty *is* the voltage, and the BIOS was driving that header at ~20%, roughly 2.4 V. That is below the fan's start-up voltage, so from a standstill it never spins:

```
fan5 = 0 rpm      while pwm5 = 20-26%     <- stalled, not idle
```

Measured directly: forcing `pwm5` to 255 started it at 1513 rpm, and handing control back to the BIOS (`pwm5_enable = 2`) left it running at 1537-1562 rpm. A DC fan needs far more voltage to break stiction than to keep turning, so once started it sustains at a duty it could never have started from.

**Resolved by raising the minimum duty to 30% in Smart Fan 6.** Verified across a cold boot: `fan5` comes up at 586 rpm on 30% duty, where it had been reading 0 rpm at 20-26%. So the start threshold sits between 26% and 30%, and the floor is now set at the first value observed to work rather than comfortably above it. If this fan ever reads 0 rpm again, that margin is the first thing to check — a stalled DC fan is silent in every sense, since the tach reads 0 exactly as an idle fan would.

Worth getting right rather than reverting to PWM mode: at PWM the fan is stuck at full and is a permanent contributor to the idle noise floor of a living-room machine.

## History is in memory only

The daemon keeps a rolling status history in RAM and starts empty on every
restart. There is no on-disk time-series database — for retention beyond that
window, scrape the Prometheus endpoint:

```
http://<this machine>:11987/metrics
```

It emits `coolercontrol_temperature_celsius`, `_fan_rpm`, `_duty_percent`,
`_frequency_hertz` and `_power_watts`, labelled by `device`, `device_uid` and
`sensor`/`channel`. It requires authentication like the rest of the API, so a
scraper needs an access token (Settings → Access Tokens in the UI).

## Network exposure

**LAN access is on** — `./install.sh --lan` was run, so the daemon binds
`0.0.0.0:11987` and the UI is reachable at `http://<this machine>:11987` from
anywhere on the home network. Revert with a plain `./install.sh`, which puts it
back to `127.0.0.1` and `[::1]`.

`--lan` sets two keys in `[settings]`:

| Key                            | Why                                                       |
| ------------------------------ | --------------------------------------------------------- |
| `ipv4_address = "0.0.0.0"`     | listen on every interface, not just loopback              |
| `allow_unencrypted = true`     | the daemon otherwise refuses plain HTTP from non-localhost |

This is full read **and** write access, protected only by the single UI
password. That is a deliberate choice, not an oversight: **CoolerControl has no
read-only mode.** There is one credential and it grants everything; even a plain
`GET /devices` is `401` without it. Access tokens exist but are for external
service authentication and carry no reduced scope. Read-only over the LAN would
mean putting a reverse proxy in front that rejects everything but `GET`/`HEAD`
and `POST /login`, which is a second daemon to install and maintain — not worth
it on a home network behind NAT.

Practical consequences:

- Anyone on the LAN who guesses the password can take over the fan curves. Use a
  real password.
- It is plain HTTP, so that password crosses the network in the clear on each
  login. The daemon does serve HTTPS on the same port with a self-signed cert
  (`https://<host>:11987`), which is worth using despite the browser warning.
- Do not port-forward this. `allow_unencrypted` exists precisely because
  upstream expects TLS for anything beyond a trusted network.

## Verified on-machine

Detected on 2026-08-02: `k10temp` (CPU package + `Tccd`), both `amdgpu` devices
(edge/junction/mem, fan, load, power, clocks), `nvme`, both MX500s via
`drivetemp`, `it8696` (6 temps, 5 fan channels), `gigabyte_wmi`, `acpitz` and
the r8169 PHY. Values match `sensors` — e.g. `fan1` 1081 RPM, `fan3` 2220 RPM,
`fan5` 1548 RPM at idle.

## References

- [CoolerControl docs](https://docs.coolercontrol.org/)
- [GitLab releases](https://gitlab.com/coolercontrol/coolercontrol/-/releases) — where `VERSION`/`SHA256` come from
