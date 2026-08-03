# Hardware sensors

Full temperature, fan and voltage coverage on SteamOS 3.8 (kernel 6.16), for
thermal logging while gaming.

**Status: working**, with one item pending a reboot (DDR5 DIMM temps — see
[FCH SMBus](#the-fch-smbus-is-blocked-by-acpi)).

## What a stock install gives you, and what it misses

Out of the box `sensors` reports CPU package temp, GPU temps, NVMe and the NIC
PHY. Everything else on this board is invisible, for three unrelated reasons:

| Missing                          | Why                                                      | Fix                        |
| -------------------------------- | -------------------------------------------------------- | -------------------------- |
| Fan RPM, Vcore, VRM temp         | ITE IT8696E Super I/O has no in-tree driver               | out-of-tree `it87`         |
| SATA SSD temps (2× MX500)        | `drivetemp` exists in the kernel but nothing autoloads it | `modules-load.d`           |
| DDR5 DIMM temps                  | FCH SMBus blocked by an ACPI resource conflict            | `acpi_enforce_resources=lax` |

## The FCH SMBus is blocked by ACPI

This is the interesting one, and it explains a second symptom that looked
unrelated: **OpenRGB not detecting the Kingston Fury RAM.**

`i2c-piix4` loads fine and then registers *zero* adapters:

```
ACPI Warning: SystemIO range 0x0B00-0x0B08 conflicts with OpRegion
              0x0B00-0x0B0F (\GSA1.SMBI) (20250404/utaddress-204)
ACPI: OSL: Resource conflict; ACPI support missing from driver?
```

The firmware declares an ACPI OperationRegion over the SMBus I/O ports. The
kernel default, `acpi_enforce_resources=strict`, makes the driver back off
rather than share the range. The result is that **this machine has no SMBus at
all** — no `i2c-N SMBus PIIX4 adapter port N` entries in `i2cdetect -l`.

So the earlier hypothesis in the top-level README — that OpenRGB was talking to
the wrong `i2c-piix4` port — was wrong. There were no ports to choose between.
Nothing on the DIMMs is reachable, RGB controllers at `0x60-0x67` included.

`acpi_enforce_resources=lax` downgrades the refusal to a warning and the
adapters appear. It is a boot parameter only; the kernel does not expose it
under `/sys/module/acpi/parameters/`.

### Why this is handled carefully

Per the platform notes in the top-level README: **AM5 has no hardware SPD write
protection.** `i2c-piix4` calls `i2c_register_spd_write_enable()`
unconditionally, and unlike Intel's `i2c-i801` there is no `SMBHSTCFG_SPD_WD`
bit for the BIOS to set. The DDR5 SPD EEPROMs at `0x50-0x57` are always
writable from the host — and on DDR5 the module temperature sensor lives
*inside* that same SPD hub. Reading DIMM temps means talking to the exact
address range that can brick the RAM.

Three things mitigate that here:

1. **`softdep i2c_piix4 post: spd5118`** (`modprobe.d/`). While `spd5118` holds
   `0x50-0x57`, userspace `ioctl(I2C_SLAVE)` on them returns `EBUSY` and
   `i2cdetect` prints `UU`. Listing `spd5118` in `modules-load.d` alone is not
   enough — `i2c-piix4` is autoloaded by PCI matching and could win the race,
   leaving a window where the hubs are exposed and unclaimed. `softdep post`
   loads `spd5118` inside `i2c_piix4`'s own modprobe, before control returns to
   userspace. **Never unbind it.**
2. **`i2c-dev` IS loaded — this was previously written up as a mitigation and is not one.** SteamOS loads it itself, via its own `/usr/lib/modules-load.d/ddcutil.conf` and `fwupd-i2c.conf`, so all 21 `/dev/i2c-*` nodes exist including the SPD bus at `/dev/i2c-2` — and `hardware/rgb/`'s udev rule grants `deck` a uaccess ACL on it. Nothing here has to opt in; the bus is already reachable from userspace. That leaves mitigation 1 as the only thing between a stray write and the SPD EEPROMs, and even that is bypassable with `I2C_SLAVE_FORCE`, which is what the tools this repo warns about use. Treat mitigation 3 as the real safety net.
3. **An SPD baseline** was captured with `dmidecode -t 17` *before* the bus was
   ever exposed, and is committed at `baseline/dmidecode-t17.txt`.
   `bin/spd-check.sh` diffs the live DMI against it. A change in size, speed,
   part number or serial is the early warning that SPD has been corrupted.
   `dmidecode` reads firmware tables and generates zero bus traffic, so running
   it is always safe.

## Sensor identification

Labels in `sensors.d/steam-machine.conf` were derived by correlation, not
guessed from board conventions. Method: sample every chip at idle, run 16 busy
loops for 70 s, sample again, stop and sample once more.

| Reading  | Idle  | Load      | Cooling | Conclusion                          |
| -------- | ----- | --------- | ------- | ----------------------------------- |
| `in0`    | 0.948 V | **1.236 V** | 0.636 V | **Vcore** — tracks load 1:1       |
| `temp3`  | 30 °C | **65 °C** | 34 °C   | **CPU** — matches `Tctl` to 0.2 °C  |
| `temp5`  | 30 °C | **42 °C** | 35 °C   | **VRM** — rises with load, lagging  |
| `temp2`  | 39 °C | 38 °C     | 38 °C   | board / chipset / M.2 area          |
| `fan1`   | 1102  | **1679**  | 1180    | **AIO radiator fans** — ramps       |
| `fan3`   | 2220  | **3139**  | 2213    | **AIO pump** — too fast for a 120mm |
| `fan5`   | 1548  | 1510      | 1544    | **case fan** — see note below       |
| `fan2`   | 0     | 0         | 0       | empty header                        |
| `temp1`  | 19 °C | 19 °C     | 19 °C   | unconnected — `ignore`              |
| `temp4`  | 22 °C | 22 °C     | 22 °C   | unconnected — `ignore`              |
| `temp6`  | 0 °C  | 0 °C      | 0 °C    | unconnected — `ignore`              |

Fan numbering is the driver's, not the board silkscreen's, so the labels
describe verified function rather than header names.

All three fan labels were re-confirmed on 2026-08-02 by an independent method —
injecting duty on one `pwmN` at a time and watching every tach, rather than
inferring from thermal response. It also pinned the `pwm`↔`fan` pairing
(`pwm1`→`fan1`, `pwm3`→`fan3`) and showed `fan5` responding to nothing. That last part was a symptom, not a property: the CPU_OPT header was in PWM mode with a 3-pin DC fan on it, so the fan saw a permanent 12 V and ignored every channel. The header is now set to Voltage/DC and `pwm5` does drive `fan5`. Its minimum duty needed raising to 30% as well: below that the DC voltage is under the fan's start-up threshold and it sits stalled at 0 rpm, indistinguishable from an idle fan. See [hardware/coolercontrol/](../coolercontrol/README.md#proving-which-tach-is-which-fan).

Two further findings:

- **`gigabyte_wmi` is redundant.** Its `temp1`–`temp5` were byte-identical to
  `it8696` `temp1`–`temp5` at all three samples — it is the same IT8696E read
  over ACPI-WMI. It is `ignore`d so logs don't double-count. If `it87` is ever
  unavailable, comment that block out to get board temps back.
- **`in1`–`in6` are unscaled ADC rails.** Gigabyte's resistor dividers are
  unknown, so the volts are meaningless and `in5`/`in6` alarm permanently.
  Ignored rather than labelled with a guess.

`temp5`'s limits read `low = +0.0°C, high = -125.0°C` — that is the firmware's,
not ours, and it is nonsense. Harmless; the reading itself is good.

## Layout

```
install.sh                     build, install, configure, load
bin/sensors-report.sh          full inventory + coverage gaps
bin/spd-check.sh               DIMM identity vs baseline
baseline/dmidecode-t17.txt     pre-SMBus SPD record
it87/upstream/                 vendored driver source + UPSTREAM_COMMIT
modules-load.d/                drivetemp, spd5118, it87
modprobe.d/                    spd5118 load-order hardening
default-grub.d/                acpi_enforce_resources=lax
sensors.d/                     labels (see table above)
systemd/                       restores it87 after SteamOS A/B updates
atomic-update.conf.d/          allowlists the /etc config so an A/B update keeps it
```

## Usage

```bash
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh       # full install
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh --no-smbus  # skip the boot param
./install.sh --status
./bin/sensors-report.sh          # what is covered, what is missing
./bin/sensors-report.sh --raw    # plus raw sysfs values
./bin/spd-check.sh               # safe to run any time
```

`install.sh` is idempotent. It caches the built module under
`~/.cache/steam-machine-sensors/`, keyed by kernel version and a hash of the
vendored source, so re-running it is a file copy rather than a rebuild.

## The it87 driver

Vendored from [frankcrawford/it87](https://github.com/frankcrawford/it87)
(commit in `it87/upstream/UPSTREAM_COMMIT`) — the maintained fork; the
`hwmon`-tree `it87` does not know this chip generation. **No source changes
were needed.**

The chip is detected natively:

```
it87: Found IT8696E chip at 0xa40 [MMIO at 0x00000000fe100000], revision 0
```

so **no `force_id` is set**, and none should be. `force_id` makes the driver
write Super I/O registers of a chip it has misidentified. It is also worth
noting the driver found the chip via MMIO, which is why it works today under
`acpi_enforce_resources=strict` — unlike the SMBus, it never hit a conflict.

The driver only reads here. Fan curves stay under BIOS control; nothing writes
`pwmN_enable`.

## Persistence

### Reboots

Everything is on disk in a location a reboot does not touch:

| Piece                         | Lives in                          |
| ----------------------------- | --------------------------------- |
| `drivetemp`, `spd5118`, `it87` autoload | `/etc/modules-load.d/`  |
| `spd5118` load-order hardening | `/etc/modprobe.d/`               |
| labels, `set` statements      | `/etc/sensors.d/` + `lm_sensors.service` |
| `acpi_enforce_resources=lax`  | `/etc/default/grub.d/` → `/efi/EFI/steamos/grub.cfg` |
| `it87.ko`                     | `/usr/lib/modules/<kver>/updates/` |

`lm_sensors.service` runs `sensors -s` on boot, which is what applies the
`set fanN_min 0` lines — without it the IT8696E keeps its 10 RPM default
minimums and alarms permanently. Labels and `ignore` need no such step.

### SteamOS A/B updates

A/B updates replace the whole `/usr` tree, taking `it87.ko` with it.
`steam-machine-sensors.service` runs `install.sh --boot` at boot, which
restores the module from the cache under `/home` — a sub-second file copy — and
only rebuilds when the kernel version has actually changed.

**`/etc` does _not_ simply "survive updates via the merge"** — an earlier version
of these notes said so, and it was wrong (corrected 2026-08-02). Since SteamOS
3.6 only an allowlisted subset carries into a new image; the default list is
`/usr/lib/rauc/atomic-update-keep.conf`. It covers
`/etc/systemd/system/*.service` and `*.wants/**`, so the unit and its enable
symlink are fine on their own. It covers **none** of the four config files this
subsystem installs:

| Path | Carries what | Consequence if lost |
| --- | --- | --- |
| `/etc/modprobe.d/` | `softdep i2c_piix4 post: spd5118` | **Safety interlock gone.** No hardware SPD write protection on this board; `spd5118` holding `0x50-0x57` is the main thing making userspace writes return `EBUSY` — on a bus `acpi_enforce_resources=lax` has deliberately opened |
| `/etc/default/grub.d/` | `acpi_enforce_resources=lax` | `i2c-piix4` registers **zero** adapters; no SMBus at all |
| `/etc/modules-load.d/` | `it87`, `drivetemp` autoload | no fan RPM / SSD temps |
| `/etc/sensors.d/` | verified labels + `set` thresholds | raw `temp1` names, default 10 RPM fan alarms |

Two fixes, both in place:

1. `atomic-update.conf.d/steam-machine-sensors.conf` allowlists those four
   **specific files** — never the directories, since an allowlisted path shadows
   all future upstream versions of it forever, and `/etc/default/grub.d` in
   particular is not ours to freeze. That file is itself on the default keep
   list, so the entry preserves itself.
2. `ensure_etc_config()` runs at the top of `do_boot()` and reinstalls any of
   them that is missing or modified, rather than only warning. It runs *before*
   `load_modules()` so the softdep is in place before `i2c_piix4` comes up, and
   needs no `unlock_rootfs` — `/etc` is an overlayfs with its upper layer in
   `/var`, writable even when `steamos-readonly` is enabled.

The grub drop-in is deliberately **not** in `ensure_etc_config()`: restoring the
file is only half the job, since `grub.cfg` must be regenerated before it reaches
the kernel. `do_boot()` handles it separately (see point 2 below).

Verified by deleting `/etc/modprobe.d/steam-machine-sensors.conf` and
`/etc/sensors.d/steam-machine.conf` and running `--boot`: both restored
byte-identically, and `modprobe -c` parses the `spd5118` softdep again.
`./install.sh --status` now reports the keep entry and lists any missing file.

Two things can still genuinely break, and neither is papered over:

1. **A kernel bump forces an `it87` rebuild**, which needs `linux-neptune-*-headers`
   from pacman and therefore the network. `--boot` retries 5 × 30 s, but if the
   matching headers are not in the repo yet, or the new kernel breaks the
   driver's build, fan RPM / Vcore / VRM temp are gone until the vendored
   source is updated. Everything else keeps working — the other drivers are
   in-tree. This is the same exposure the MT7902 Bluetooth driver already
   carries.
2. **An update may write a canned `grub.cfg`** for the slot it installs into
   rather than regenerating it from `grub-mkconfig`. If it regenerates, the
   drop-in in `/etc/default/grub.d/` is sourced and the parameter survives; if
   it does not, the parameter is silently dropped and DIMM temps disappear.
   `--boot` detects exactly this — drop-in present, parameter absent from
   `/proc/cmdline` — and regenerates `grub.cfg` automatically. That fixes the
   *next* boot; the boot it detects on still has no SMBus.

Check either at any time with `./install.sh --status`.

## Known gaps

- **DDR5 DIMM temps need a reboot.** The grub drop-in is installed and
  `/efi/EFI/steamos/grub.cfg` regenerated, but `acpi_enforce_resources=lax`
  only takes effect on the next boot. Verify afterwards with
  `./bin/sensors-report.sh` — expect `piix4` adapters and `spd5118` bound to
  `N-0050`/`N-0051`.
- **`pwm4` reads 0%** with no corresponding fan. Either an unused header or a
  header whose tach is not wired.
- **PSU telemetry**: none. The Corsair SF850 is not a digital (`corsairpsu`)
  unit — no sensor exists to read.
- **Per-drive SATA labels**: SATA enumeration is not stable across reboots, so
  `drivetemp-scsi-0-0` and `-1-0` can swap. Both are labelled `SATA SSD`; use
  `bin/sensors-report.sh` to map an instance to `/dev/sdX` and its model.

## References

- [frankcrawford/it87](https://github.com/frankcrawford/it87) — IT8696E support
- `Documentation/hwmon/it87.rst`, `drivetemp.rst`, `spd5118.rst` in the kernel tree
- `acpi_enforce_resources`: `Documentation/admin-guide/kernel-parameters.txt`
