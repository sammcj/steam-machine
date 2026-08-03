# Disabling Kingston Fury DDR5 RGB on SteamOS

Plan for turning the RGB LEDs off on Kingston Fury DDR5 modules and keeping them off, without putting the SPD EEPROM at risk.

## TL;DR

- The LEDs are driven by a separate microcontroller on each DIMM at SMBus address `0x60 + slot`. The SPD EEPROM is a different chip at `0x50 + slot`. The documented DDR5 bricking cases all trace back to writes at `0x50-0x57`.
- The plan is a single self-contained script that only ever opens `0x60-0x67`, refuses any other address, and never scans the bus.
- Fury RGB state is volatile. It resets to rainbow on every power cycle, so a systemd oneshot at boot (plus a resume hook) is required. There is no "save to the module" command.
- The installed solution has no dependencies beyond the Python already in SteamOS, so there is nothing to reinstall after an OS update. Some optional phases (the SPD backup) do need packages temporarily.

## How to run this plan

This is executed by an agent with root shell access on the SteamOS box, working alongside a human who is physically at the machine. Several steps cannot be done by either one alone.

**Human only.** An agent cannot do these and must stop and ask:

- Any BIOS change (phase 0, and the SPD write toggle in phase 2).
- Observing whether the LEDs are actually off. There is no software readback that proves the light stopped; the register readback in `--status` proves the register took, which is not the same thing.
- Power cycling and suspend/resume testing in phase 5.

**Agent.** Everything else: writing the script, running read-only recon, running `--dry-run`, installing units, reading logs.

**Record findings in `hardware/ram/findings.md`** as you go, committed to this repo. Phase 1 output is the baseline that phase 7 diffs against, so it has to be written down rather than left in scrollback.

### Stop immediately if

Any of these means something is wrong with an assumption in this document. Do not retry, do not work around, capture the state and reassess:

- `--scan` reports a `FURY` signature at a different number of addresses than `dmidecode -t 17` reports populated modules.
- A model code outside `{0x10, 0x11, 0x12, 0x15}` comes back.
- `ioctl(I2C_SLAVE)` returns `EBUSY` for an address in `0x60-0x67`, meaning a kernel driver already owns it.
- `dmidecode -t 17` differs from the phase 1 baseline in size, speed, part number or serial. This is the SPD damage canary.
- The machine reports the wrong total RAM, drops to JEDEC speeds unprompted, or fails to POST.
- A register write fails and the retry also fails.

On the last three, go to [ddr5-spd-recovery](https://github.com/ubihazard/ddr5-spd-recovery) before touching anything else.

### Done when

- Cold boot twice with the LEDs going out shortly after the OS loads, confirmed by a human looking at the machine.
- `journalctl -u fury-rgb-off.service -b` shows the expected addresses written and no errors.
- `dmidecode -t 17` matches the phase 1 baseline byte for byte on size, speed, part number and serial.
- The repo contains: this plan, `fury-rgb`, `install.sh`, the unit files, and `findings.md` with real recorded values.

## 1. This machine

From the build list in the repo README:

- **RAM**: Kingston FURY Beast RGB Black 32GB (2x16GB) DDR5-6000 CL36, SKU `KF560C36BBE2AK2-32`. The `KF5` prefix is what kfrgb matches on. The `BBE2` in the SKU suggests the second Beast revision, so expect model code `0x15` (`FURY_MODEL_BEAST2_DDR5`), with `0x10` as the other likely answer. Confirm in phase 1.
- **Board**: Gigabyte B850M FORCE WIFI6E V2, AM5. AMD FCH, so the SMBus driver is `i2c-piix4`, not `i2c-i801`. `i2c-piix4` registers several ports (`SMBus PIIX4 adapter port 0 at 0b00`, `port 2 at 0b20`, and so on) and only one of them carries the DIMMs. Getting the right one matters; `--scan` finding no `FURY` signature most likely means the wrong port, not missing hardware.
- **CPU**: Ryzen 7 9800X3D. Not directly relevant beyond confirming the AMD SMBus path.
- **Case**: Lian Li DAN-A3 with a steel mesh side panel. The mesh already diffuses some light, which makes the physical option in section 4 more palatable than it would be behind glass.

Two modules in a board with four slots normally sit in A2/B2, which puts their SPD at `0x51` and `0x53` and their RGB controllers at `0x61` and `0x63`. On a two-slot board it would be `0x60` and `0x61`. Phase 1 settles it.

Gigabyte's BIOS RGB controls live under RGB Fusion. Historically these cover onboard zones and headers rather than DIMM modules, so do not expect phase 0 to solve this outright, but check.

## 2. Why the scare stories happen

From [ddr5-spd-recovery](https://github.com/ubihazard/ddr5-spd-recovery):

- A DDR5 module carries an SPD5118 hub (JEDEC JESD300) at `0x50-0x57` holding 1024 bytes of SPD: JEDEC timings, part number, serial, XMP and EXPO profiles.
- Those 1024 bytes are reached through eight 128-byte pages, and the page is selected by _writing_ a register on the hub. Reading the whole SPD therefore requires writing to it.
- Corruption comes from bad writes to that hub, or from two programs racing on the page pointer. Per-byte bus locking does not save you: one program can switch the page between another program's two byte accesses, so the second program's write lands in the wrong page.
- Symptoms: half your RAM disappearing, garbage part numbers and serials, absurd timings, XMP failing, eventually not POSTing.
- OpenRGB is the repeat offender because it enumerates DIMMs by reading SPD and probes across the whole bus.

The failure mode is specific: writes landing in the SPD hub at `0x50-0x57`. Every documented case traces back there. That is what makes a narrowly targeted script defensible where a general-purpose RGB daemon is not.

### What has changed since those articles

OpenRGB has supported these modules since July 2024, not recently. [MR !2435](https://gitlab.com/CalcProgrammer1/OpenRGB/-/merge_requests/2435) "Support for Kingston Fury DDR4/5 DIMMs" was merged on 2024-07-23 and closed [issue #2879](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/2879). The earlier [MR !1887](https://gitlab.com/CalcProgrammer1/OpenRGB/-/merge_requests/1887) was closed without merging two days later. `Controllers/KingstonFuryDRAMController/` is in master today. So "OpenRGB doesn't detect my Fury RAM" is roughly two years out of date, and if it is not detecting them on this machine the cause is something local, not missing support.

It still isn't the right tool here:

- Its detection path enumerates DIMMs through an SPD wrapper, so it reads `0x50-0x57` on every startup.
- The DDR5 SPD corruption meta-issue [#4934](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/4934) is still open.
- Known open bugs on this exact hardware: dual-DIMM kits detecting only one stick ([#4981](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/4981)), unhandled model code 0x13 ([#4921](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/4921)).
- It is a daemon with a GUI, a server socket and a plugin system, for a job that is six register writes once per boot.

## 3. Hardware facts

Sources: OpenRGB `KingstonFuryDRAMController.h` (merged master), [kfrgb](https://github.com/KeyofBlueS/kfrgb), the [topalovic gist](https://gist.github.com/topalovic/190ec9cd62b51270e7e273ecbcb134d9), and OpenRGB issue #2879.

### Address map (host SMBus)

| Address range | Device | We touch it? |
| --- | --- | --- |
| `0x48-0x4F` | DDR5 PMIC | no |
| `0x50-0x57` | SPD5118 hub, including the module thermal sensor | **never** |
| `0x60-0x67` | Kingston Fury RGB MCU, one per slot | yes, this only |

Slot index is the same in both ranges: the module whose SPD is at `0x51` has its LED controller at `0x61`. On a typical two-DIMM install in the A2/B2 slots that is `0x61` and `0x63`.

Note that DDR5 moved the module temperature sensor inside the SPD5118 hub, so it shares the dangerous address range. On DDR4 it was a separate device at `0x18-0x1F`. Anything reading DIMM temperatures on DDR5 is therefore talking to `0x50-0x57`. Through the kernel's `spd5118` hwmon driver that is fine, because the driver owns the address and serialises access. Through a userspace tool poking `/dev/i2c-*` it is not.

### Register map on the RGB MCU

| Register | Meaning | Value we write |
| --- | --- | --- |
| `0x08` | Transfer control | `0x53` to begin, `0x44` to commit |
| `0x09` | Mode | `0x00` (static) |
| `0x20` | Brightness, `0x00` to roughly `0x64` | `0x00` |
| `0x31` `0x32` `0x33` | Static mode R, G, B | `0x00` each |

Identification, read only, and worth getting exactly right:

- The ASCII signature `F` `U` `R` `Y` (`46 55 52 59`) lives at byte offsets `0x02` to `0x05`, and the model code at offset `0x07`.
- OpenRGB reaches them with SMBus **read-word** at registers `0x01` to `0x04` and `0x06`, taking the **high byte** of each result (`res >> 8`). Its `FURY_REG_MODEL = 0x06` constant is therefore off by one from the actual byte offset. kfrgb reaches the same bytes with an I2C block read and indexes `0x02-0x05` and `0x07` directly. Both agree on the underlying layout.
- Copy one of those two access patterns. A plain read-byte at `0x02` is untested on this controller and may not return what you expect.

Model codes: `0x10` Beast DDR5, `0x11` Renegade DDR5, `0x12` Beast RGB White DDR5, `0x15` Beast2 DDR5. Code `0x13` is seen in the wild and not yet classified upstream, so treat an unknown code as a reason to stop rather than a reason to proceed.

The `0x53` / `0x44` bracket is ASCII `S` and `D`. Every write sequence must be wrapped in it or the module ignores the changes.

### Persistence

Settings are not expected to survive a power cycle. No source states this outright; it is inferred from three things, and phase 5 is what actually confirms it on this hardware:

- No implementation exposes a save or commit-to-flash command. The `0x53` / `0x44` pair brackets a transfer, and nothing writes anywhere else.
- The Windows [KingstonFuryRgbCLI](https://github.com/Beej126/KingstonFuryRgbCLI) is documented as being run from a Startup shortcut, which would be pointless if the module remembered.
- Community reports of OpenRGB and kfrgb users needing a startup profile agree.

Consequence: the boot-time unit is the whole persistence mechanism.

Also expect the lights during POST regardless. Nothing running under Linux can suppress the few seconds before the OS loads.

## 4. Options considered

**Check the BIOS first.** If the board exposes a DIMM or system LED toggle (MSI "EZ LED Control", ASUS Aura on/off, Gigabyte RGB Fusion off-state settings), use it. Zero SMBus traffic from the OS is strictly better than anything below, and it also covers POST. Board-level toggles often only cover onboard headers rather than DIMMs, so check whether it actually kills the RAM lighting.

**Physical.** Opaque tape over the light bars, or pulling the diffuser. Zero risk and it survives every OS update. Looks terrible through a windowed case. Worth remembering as the fallback if the SMBus route misbehaves.

**OpenRGB.** Covered above. No.

**kfrgb.** The protocol values are right and it is the best documentation of this hardware in existence. As an installed tool it is a poor fit:

- Needs `i2c-tools`, `yad`, `perl` and `lshw` present, all of which means pacman on an immutable rootfs.
- Its detection runs a full-bus `i2cdetect -y <bus>`, which quick-writes across `0x03-0x2F`, `0x38-0x4F` and `0x60-0x77` (auto mode only avoids quick-write on `0x30-0x37` and `0x50-0x5F`, where it uses receive-byte instead).
- To make that scan see everything, it **unbinds the `spd5118` kernel driver** from the SPD addresses. That deliberately removes the kernel's protection over `0x50-0x57` for the duration of the run. That is the single thing we most want to keep in place.

Its `--simulation` flag does not make it safe to run either: `i2cset_retry()` skips the simulation branch whenever `detection` is set, so the detection pass writes for real no matter what you pass. Read it, borrow its constants, do not execute it here.

**Purpose-built script.** Recommended. Roughly 150 lines, no dependencies beyond the Python in the base image, only ever opens `0x60-0x67`.

## 5. Hard safety rules

These are constraints on both the script and the operator.

1. **Never install or run OpenRGB on this machine.** Not for the RAM, not for fans, not for anything.
2. **Never run a bare `i2cdetect -y <bus>`.** If a scan is genuinely needed, restrict it: `i2cdetect -y -r <bus> 0x60 0x67`. The `-r` forces receive-byte instead of quick-write, and the range keeps it off the PMIC and SPD.
3. **The script hard-fails on any address outside `0x60-0x67`.** Use an explicit `if not (0x60 <= addr <= 0x67): raise SystemExit(...)`, not `assert`. `assert` is stripped by `python -O` and `PYTHONOPTIMIZE=1`, and a guard that a stray environment variable can remove is not a guard.
4. **Understand that this board has no hardware SPD write block.** On Intel the SMBus host controller has an SPD write disable bit (`SMBHSTCFG_SPD_WD` in `i2c-i801`), which BIOS sets and which blocks host writes to `0x50-0x57` in hardware. AMD's `i2c-piix4` has no equivalent; it calls `i2c_register_spd_write_enable()` unconditionally. So on this machine the protection is the script's address range check plus rule 5, and nothing underneath them. Treat the address guard as the only thing standing between you and a dead kit, because on AMD it is. If the Gigabyte BIOS does expose an SPD write protection option, turn it on anyway and record what it changes.
5. **Keep `spd5118` bound.** When a kernel driver owns an I2C address, `ioctl(I2C_SLAVE)` from userspace returns `EBUSY` (this is the `UU` you see in `i2cdetect` output). The script uses `I2C_SLAVE`, never `I2C_SLAVE_FORCE`, so it structurally cannot steal an address from a bound driver. Never unbind `spd5118`.
6. **One writer at a time.** `flock` on `/run/lock/fury-rgb.lock` so the boot run and a resume run cannot overlap on the bus.
7. **No other SMBus consumers.** No RGB daemons, no fan control software, and no userspace tool that reads DIMM temperatures, since on DDR5 that means reading `0x50-0x57`.
8. **Reads before writes.** Identify by reading the `FURY` signature. Write only after it matches.

## 6. Procedure

Each phase produces a decision. Do not skip ahead; phase 1 output is what makes phase 4 safe.

Write and review the script from section 7 before starting, since phase 1 uses its read-only `--scan` mode. Read the finished script end to end before running it as root. It is short enough that this is a five minute job, and it is the only real assurance that the address guard is where it claims to be.

### Phase 0: BIOS

- Look for a DIMM/system LED control. If it turns the RAM off, stop here, you are done.
- Confirm SPD write protection is enabled (named "SPD Write Disable", "SPD Write Protect" or similar). Leave it that way.
- Note whether XMP/EXPO is on. If SPD ever does get damaged, resetting BIOS to drop back to the JEDEC profile is the first recovery step.

### Phase 1: read-only reconnaissance

No writes. Record all output in this repo so later phases and any future debugging have a baseline.

- `grep . /sys/class/i2c-dev/*/name` to list the adapters without needing `i2c-tools`. On this AMD board expect several `SMBus PIIX4 adapter port N at 0bXX` entries. (`i2cdetect -l` gives the same thing and also generates no bus traffic, if the package happens to be installed.)
- `ls -l /sys/bus/i2c/drivers/spd5118/` does two jobs at once: it confirms the SPD hubs are claimed by the kernel, and it **identifies which piix4 port carries the DIMMs**. Entries look like `0-0050`, `0-0051`, where the prefix is the bus number. Kernel patches from mid-2024 auto-instantiate `spd5118` on the correct port, so this is authoritative rather than inference. The Fury RGB controllers are on that same bus. Use this in preference to guessing from adapter names.
- `lsmod | grep -E 'i2c_|spd5118'` and `ls /dev/i2c-*` to check `i2c-dev` and the platform SMBus driver are loaded.
- `sudo dmidecode -t 17` for populated slots, part numbers and serials. Confirms `KF5*` Fury parts and tells you how many controllers to expect, with no bus traffic at all.
- `fury-rgb --scan` (script mode below): reads the signature at `0x60-0x67` and prints which slots answer with `FURY` plus their model code.

Decision point: the set of addresses that answer `FURY` is the complete list of addresses the script will ever write to. If it does not match the DIMM count from `dmidecode`, stop and work out why.

### Phase 2: SPD backup (optional, and a genuine trade-off)

A verified SPD dump is the difference between "reflash and carry on" and "RMA or bin it". Getting one is also the riskiest thing in this whole document, because reading all 1024 bytes requires writing the page-select register on the SPD hub, and requires turning BIOS SPD write protection **off** to do it.

- **Take the backup** if you want a recovery path. Procedure: enable SPD writes in BIOS if the option exists, boot with nothing else running, `spdread.py` each module, `spdinfo.py` to verify every CRC matches, reboot, turn the option back off. Do this _before_ any RGB work. Note that ddr5-spd-recovery needs `i2c-tools`, `dmidecode` and the `i2c_dev` module, so this phase does require temporarily installing packages.
- **Skip the backup** if you would rather never point a writing tool at the SPD hub at all. The RGB work never touches `0x50-0x57`, so skipping costs nothing in day-to-day risk; it costs you the recovery image if something else damages SPD later.

Recommendation for this machine: **skip it**, and revisit only if you later decide you want the insurance. The reasoning changed once the board turned out to be AMD. On Intel, BIOS SPD write protection is a hardware block in the SMBus controller, so taking a backup means deliberately lifting that block for one boot and putting it back. On AMD there is no such block to lift or restore, which removes the tidy "one controlled window" framing: the only tool that would write to the SPD hub in this entire plan is the backup tool itself. Not running it is the lowest-risk position available.

If you want insurance without that trade, buy a second identical kit or rely on warranty. Kingston FURY carries a limited lifetime warranty, and an RMA is a better recovery path than a self-flash for most people.

Cheaper middle ground: run `spdcheckrswp.py` to see whether Kingston already set reversible write protection on the important blocks from the factory. Kingston generally does. If blocks 0-13 are already protected, the sections that matter are protected in hardware and the case for a backup weakens.

Do **not** run `spdsetrswp.py`. Setting RSWP yourself is irreversible without a hardware programmer, and on an RGB module you would need to know exactly which blocks the lighting uses.

If you do take dumps: the `.spd` files contain module serial numbers. Keep them out of a public repo, or keep this repo private.

### Phase 3: dry run

- `fury-rgb --off --dry-run` prints every transaction it would perform, address by address, and exits without opening the bus for writing.
- Read that output and confirm every address is in `0x60-0x67` and matches phase 1.
- Cross-check the register sequence by **reading** kfrgb's source, not by running it. Its `--simulation` flag is not a full dry run: `i2cset_retry()` only suppresses writes when `detection != true`, so the detection pass performs real `i2cset` writes regardless of the flag, on top of running a full-bus `i2cdetect -y` and unbinding `spd5118`. Do not run kfrgb on this machine at all.

### Phase 4: one-shot apply

- `sudo fury-rgb --off` with nothing else running.
- Lights should go out immediately.
- `fury-rgb --status` reads back mode, brightness and the static colour registers to confirm they took.

### Phase 5: persistence testing

Establish what actually needs re-applying:

- Full shutdown, wait for the PSU to drop, power on. Expect the lights to come back (rainbow). This confirms the boot unit is needed.
- Suspend and resume. Note whether the lights come back. This decides whether the resume hook is needed.
- Reboot without power loss. Note the behaviour.

Record the results in this document. They determine which units get installed in phase 6.

### Phase 6: install

Script, systemd units and module config, per section 8.

### Phase 7: verify

- `systemctl status fury-rgb-off.service` and `journalctl -u fury-rgb-off.service -b`.
- Cold boot twice and confirm the lights go out shortly after the OS loads.
- Re-run the phase 1 read-only checks and confirm `dmidecode -t 17` still reports the correct part numbers, serials, size and speed. This is the canary for SPD damage. Do this after the first few boots, then occasionally.

## 7. Script design

One file, `hardware/ram/fury-rgb`, Python 3, standard library only.

### Why not i2c-tools

Talking to `/dev/i2c-N` is two ioctls. Doing it directly means no `i2c-tools` package, which means nothing to reinstall after a SteamOS update and nothing to go missing at boot. It also lets the address guard live inside the same process that opens the device, rather than being a shell string that could be mistyped.

The SMBus ioctl interface needed:

- `I2C_SLAVE` (`0x0703`) to select the target address. Deliberately not `I2C_SLAVE_FORCE`, so a kernel-claimed address fails with `EBUSY` instead of being hijacked.
- `I2C_SMBUS` (`0x0720`) with `i2c_smbus_ioctl_data`, using `I2C_SMBUS_WORD_DATA` for the identification reads and `I2C_SMBUS_BYTE_DATA` for the writes.

Appendix A has the constants and struct layout.

### CLI

- `--scan` read-only, prints which of `0x60-0x67` answer with the `FURY` signature and their model code.
- `--off` apply the off sequence to every detected controller.
- `--status` read back mode, brightness and RGB registers.
- `--dry-run` print transactions, perform none.
- `--bus N` override adapter selection.
- `--slots 1,3` restrict to specific slots.

### Algorithm

```
select bus:
  preferred: ls /sys/bus/i2c/drivers/spd5118/   -> entries "N-0050"; N is the DIMM bus
             this is exact, needs no bus traffic, and needs no i2c-tools
  fallback:  read /sys/class/i2c-dev/*/name, match "SMBus PIIX4 adapter" (AMD,
             this machine) or "SMBus I801 adapter" (Intel)
  --scan  ->  probe every candidate read-only, report which one answered
  --off   ->  require exactly one candidate, or an explicit --bus; otherwise refuse

for addr in 0x60..0x67:
  if not (0x60 <= addr <= 0x67): abort  # explicit raise, never assert (see rule 3)
  ioctl(I2C_SLAVE, addr)                # EBUSY here means a driver owns it: skip
  read_word(0x01..0x04) >> 8            # read-only probe, no begin-transfer write
  if != "FURY": skip this address       # no writes ever happen to a non-Fury device
  read_word(0x06) >> 8 -> model code
  if model not in {0x10,0x11,0x12,0x15}: skip and warn

for each detected controller:
  write 0x08 = 0x53                     # begin
  write 0x09 = 0x00                     # static mode
  write 0x31 = 0x00                     # red
  write 0x32 = 0x00                     # green
  write 0x33 = 0x00                     # blue
  write 0x20 = 0x00                     # brightness
  write 0x08 = 0x44                     # commit
  # settle between writes; references disagree on how long
```

The three reference implementations use different inter-write delays: 10 ms in OpenRGB, 15 ms in kfrgb, 20 ms in the topalovic gist. None explains why. Start at 20 ms, since this runs once per boot and there is no reason to be quick about it. The maximum brightness value is similarly unsettled (`0x63` in the gist, `0x64` in kfrgb); it does not matter here because we write `0x00`.

Design notes:

- The read-only probe comes first, unbracketed. OpenRGB writes `0x08 = 0x53` before probing and uses that write failing as its "no DIMM here" test, which means it writes a data byte to a device it has not identified yet. kfrgb reads first and only falls back to the bracketed probe if the signature does not match. Follow kfrgb. A read-word-data still puts a command byte on the wire, so it is not zero-traffic, but it never delivers a data byte to an unknown device. This matters because `0x60-0x67` is not exclusively Kingston's; some boards place Aura or similar controllers in the same neighbourhood. If plain reads come back empty on hardware that should work, put the bracketed fallback behind an explicit flag rather than making it the default.
- Both brightness zero and colour black are written. Either alone should do it; both together means a partially-applied sequence still ends dark.
- `flock` on `/run/lock/fury-rgb.lock` for the whole run.
- Retry loop around the initial bus open: at early boot the adapter may not be ready. A handful of attempts a second apart, then fail loudly.
- Non-zero exit on signature mismatch, and no writes in that case.
- Detection must be all-or-nothing against an expected count. At boot the bus can answer for one module and not yet the other, and a run that quietly turns off one stick looks like success in the journal. Pass the expected count in (recorded in `findings.md` from phase 1, or derived from DMI at runtime), retry the whole scan until it matches, then fail loudly rather than acting on a partial result.
- Whatever suppresses writes in `--dry-run` must cover the detection path too. kfrgb's bug is exactly this: its `i2cset_retry()` skips the simulation branch when `detection` is set, so its dry run is not dry. Structure this so there is one write function and one place that checks the flag.
- Log to stdout so `journalctl -u fury-rgb-off` shows exactly which addresses were written.

### Explicitly not implemented

- No colour or mode setting. The tool does one thing.
- No bus scanning beyond `0x60-0x67`.
- No SPD access of any kind. No device address below `0x60` appears anywhere in the file.
- No unbinding of kernel drivers.

## 8. Persistence on SteamOS

SteamOS 3.x makes this the fiddly part. The root filesystem is a read-only btrfs image in an A/B pair; an OS update writes a whole new image to the inactive slot and boots into it. Anything installed into `/usr`, `/opt` or `/usr/local` after `steamos-readonly disable` is gone after the next update, because the new image simply does not contain it.

What this rules out:

- `pacman -S i2c-tools`. Wiped on every update. This is the main reason the script has no package dependencies.
- `/usr/lib/systemd/system-sleep/`, the normal place for resume hooks. It is on the read-only rootfs.

What survives:

- `/home` - separate partition, always persists.
- `/etc` - an overlayfs with its upper layer in `/var/lib/overlays/etc/upper`, so edits always survive reboots. Since SteamOS 3.6 only an allowlisted subset of `/etc` is carried into a new OS version on update, so reboot persistence and update persistence are different questions.
- `/etc/atomic-update.conf.d/` - the supported way to add your own paths to that keep list. There is an example template at `/etc/atomic-update.conf.d/example-additional-keep-list.conf`.

### Layout

- Repo cloned to `/home/deck/...` for convenience. Nothing is executed from there by root.
- Script installed to `/etc/fury-rgb/fury-rgb`, root-owned, mode 755. `/etc` gives root ownership plus reboot persistence in one place. Do not point the systemd unit at the clone in `/home`: root would then be executing a file that a non-root user can rewrite.
- `/etc/systemd/system/fury-rgb-off.service`, `Type=oneshot`, `RemainAfterExit=yes`, `After=systemd-modules-load.service`, `WantedBy=multi-user.target`. Ordering after the module load unit is what guarantees `/dev/i2c-*` exists; the script's retry loop covers the rest.
- `/etc/modules-load.d/i2c-dev.conf` containing `i2c-dev`. It is present in the SteamOS kernel but not auto-loaded. `i2c-piix4` is auto-loaded on AMD; add the platform driver here too if phase 1 shows otherwise.
- Resume, if phase 5 shows it is needed: a second unit in `/etc/systemd/system` with `After=sleep.target` and `WantedBy=sleep.target`. Use `sleep.target` rather than `suspend.target`: suspend, hibernate, hybrid-sleep and suspend-then-hibernate all pull in `sleep.target`, so one unit covers every path back from a low-power state.
- `/etc/atomic-update.conf.d/50-fury-rgb.conf` listing everything above so it carries across OS updates.

The keep list has to name every installed path, including the ones `systemctl enable` creates and the keep-list file itself:

```
/etc/fury-rgb/fury-rgb
/etc/systemd/system/fury-rgb-off.service
/etc/systemd/system/multi-user.target.wants/fury-rgb-off.service   <- enable symlink
/etc/systemd/system/fury-rgb-resume.service                        <- if used
/etc/systemd/system/sleep.target.wants/fury-rgb-resume.service      <- if used
/etc/modules-load.d/i2c-dev.conf
/etc/atomic-update.conf.d/50-fury-rgb.conf
```

The syntax of that file is not documented publicly. Read `/etc/atomic-update.conf.d/example-additional-keep-list.conf` on the machine and copy its exact form, including how it handles globs, recursion and symlinks. Do this before writing `install.sh`, not after.

`hardware/ram/install.sh` performs the copies, enables the units and prints what it changed. Make it idempotent and safe to re-run after any SteamOS update, since the keep-list mechanism is the documented path but is not something to rely on blindly. Re-run it and check every path above after the first OS update.

Python 3 is in the base image (SteamOS's own update client is Python), so the script has an interpreter without installing anything.

## 9. Rollback

Nothing here is destructive, and all of it is reversible without hardware:

- Stop and disable the units, delete them, `systemctl daemon-reload`.
- Power cycle. The modules come back up in their default rainbow mode because RGB state is volatile.
- To restore lighting without a reboot, add a `--mode` variant to the script that writes a non-zero brightness and colour through the same guarded path. Reaching for kfrgb or OpenRGB to do it would reintroduce exactly the bus behaviour this plan avoids.

## 10. Open questions to resolve on the machine

- Whether the Gigabyte B850M BIOS can kill DIMM lighting directly (phase 0).
- Which `i2c-piix4` port carries the DIMMs, and its bus number.
- Which DIMM slots are populated, and therefore which `0x6X` addresses to expect.
- The model code the modules actually report (expected `0x15`, possibly `0x10`).
- Whether the lights return after suspend/resume, and after a warm reboot.
- Whether `spd5118` is bound on this kernel. If it is not, the `EBUSY` protection over `0x50-0x57` is absent and the script's address guard is doing all the work on its own.
- Whether `modprobe i2c-dev` works. There is a 2023 report of an "invalid ELF" failure on SteamOS 3.4.6; almost certainly stale, but confirm before relying on `modules-load.d`.
- Whether the `/etc/atomic-update.conf.d` keep list actually preserves all four installed files across a real OS update. Check after the first one.

## 11. References

- [ddr5-spd-recovery](https://github.com/ubihazard/ddr5-spd-recovery) - the corruption mechanism, symptoms, and recovery tooling.
- [kfrgb](https://github.com/KeyofBlueS/kfrgb) - working Linux implementation, best reference for the protocol and model detection.
- [topalovic gist](https://gist.github.com/topalovic/190ec9cd62b51270e7e273ecbcb134d9) - minimal 80-line version showing the exact register sequence.
- [KingstonFuryRgbCLI](https://github.com/Beej126/KingstonFuryRgbCLI) - Windows decompile of FURY CTRL; confirms the settings need re-applying at startup.
- [OpenRGB issue #2879](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/2879) - the reverse engineering thread.
- [OpenRGB MR !2435](https://gitlab.com/CalcProgrammer1/OpenRGB/-/merge_requests/2435) - the merged Fury DDR4/5 support, source of the register names used above. [MR !1887](https://gitlab.com/CalcProgrammer1/OpenRGB/-/merge_requests/1887) is the earlier attempt that was closed unmerged; do not cite it.
- [OpenRGB issue #4934](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/4934) - open DDR5 SPD corruption meta-issue.
- [Keeping system-wide configuration files intact after updating SteamOS](https://blogs.igalia.com/berto/2025/02/05/keeping-your-system-wide-configuration-files-intact-after-updating-steamos/) - the `/etc` overlay and `atomic-update.conf.d` keep list.
- [SteamOS update internals](https://github.com/randombk/steamos-teardown/blob/master/docs/system-updates.md) - A/B image swap and which partitions survive.
- [ArchWiki: I2C](https://wiki.archlinux.org/title/I2C) - `i2c-dev` and `modules-load.d`.

## Appendix A: SMBus ioctl reference

Everything needed to talk to `/dev/i2c-N` without `i2c-tools`. Constants from `linux/i2c-dev.h` and `linux/i2c.h`.

```
I2C_SLAVE                0x0703   /* set target address, fails EBUSY if a driver owns it */
I2C_SLAVE_FORCE          0x0706   /* do not use */
I2C_FUNCS                0x0705   /* query adapter capabilities */
I2C_SMBUS                0x0720   /* perform a transfer */

I2C_SMBUS_WRITE          0
I2C_SMBUS_READ           1

I2C_SMBUS_BYTE_DATA      2
I2C_SMBUS_WORD_DATA      3
I2C_SMBUS_I2C_BLOCK_DATA 8

union i2c_smbus_data { u8 byte; u16 word; u8 block[34]; };
struct i2c_smbus_ioctl_data { u8 read_write; u8 command; u32 size; union i2c_smbus_data *data; };
```

The struct has two padding bytes between `command` and `size`, and the pointer is 8-byte aligned on x86-64. `ctypes` handles both if you declare the fields in order.

```python
import ctypes, fcntl

I2C_SLAVE, I2C_SMBUS = 0x0703, 0x0720
SMBUS_WRITE, SMBUS_READ = 0, 1
BYTE_DATA, WORD_DATA = 2, 3

class SmbusData(ctypes.Union):
    _fields_ = [("byte", ctypes.c_uint8),
                ("word", ctypes.c_uint16),
                ("block", ctypes.c_uint8 * 34)]

class SmbusIoctl(ctypes.Structure):
    _fields_ = [("read_write", ctypes.c_uint8),
                ("command", ctypes.c_uint8),
                ("size", ctypes.c_uint32),
                ("data", ctypes.POINTER(SmbusData))]

def _xfer(fd, read_write, command, size, data):
    fcntl.ioctl(fd, I2C_SMBUS,
                SmbusIoctl(read_write, command, size, ctypes.pointer(data)))

def read_word(fd, reg):
    d = SmbusData()
    _xfer(fd, SMBUS_READ, reg, WORD_DATA, d)
    return d.word

def write_byte(fd, reg, val):
    d = SmbusData()
    d.byte = val
    _xfer(fd, SMBUS_WRITE, reg, BYTE_DATA, d)
```

Select the address with `fcntl.ioctl(fd, I2C_SLAVE, addr)` after the range check, and let `OSError` with `errno.EBUSY` propagate rather than retrying with `I2C_SLAVE_FORCE`.

The signature check, matching OpenRGB's access pattern:

```python
sig = bytes((read_word(fd, r) >> 8) & 0xFF for r in range(1, 5))   # -> b"FURY"
model = (read_word(fd, 0x06) >> 8) & 0xFF                          # -> 0x10/0x11/0x12/0x15
```

## Appendix B: files to install

Exact contents, so `install.sh` is a copy rather than an interpretation.

`/etc/systemd/system/fury-rgb-off.service`

```ini
[Unit]
Description=Turn off Kingston Fury DDR5 RGB
After=systemd-modules-load.service
ConditionPathExistsGlob=/dev/i2c-*

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/fury-rgb/fury-rgb --off

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/fury-rgb-resume.service`, only if phase 5 shows it is needed:

```ini
[Unit]
Description=Turn off Kingston Fury DDR5 RGB after resume
After=sleep.target

[Service]
Type=oneshot
ExecStart=/etc/fury-rgb/fury-rgb --off

[Install]
WantedBy=sleep.target
```

`/etc/modules-load.d/i2c-dev.conf`

```
i2c-dev
```

`/etc/atomic-update.conf.d/50-fury-rgb.conf`: contents depend on the syntax of the on-device example template. Read it first.
