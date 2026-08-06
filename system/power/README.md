# Idle power

Tunables for the machine sitting on the Deck UI doing nothing, plus the measurement tool for deciding whether any future one is worth having.

```sh
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh --status   # package watts need root
```

No reboot needed: both tunables are runtime-writable, unlike the modprobe parameters in [hardware/gpu/](../../hardware/gpu/README.md) and [hardware/sensors/](../../hardware/sensors/README.md).

## The number that started this, and why it was wrong

`powertop` was run on 2026-08-03 because the CPU appeared to sit at 4 GHz+ permanently. It does not.

`scaling_cur_freq` and `/proc/cpuinfo` both derive frequency from APERF/MPERF, and **on AMD those counters only tick in C0**. They report the clock during the awake slices and are blind to halted time entirely. At desktop idle they read ~4.1 GHz on a machine that is asleep 93% of the time.

Measured residency, cpu0, over 1159 s of uptime:

| State  | Time    | Share |
| ------ | ------- | ----- |
| C3 (CC6) | 891.9 s | 77%   |
| C2     | 158.7 s | 13.7% |
| C1     | 31.6 s  | 2.7%  |
| POLL   | 1.2 s   | 0.1%  |

93.4% idle, corroborated two other ways: `/proc/uptime` (8680 s of idle ÷ 8 cores ÷ 1159 s) and powertop's own *Package: Idle 100.0%*.

So `amd-pstate-epp` + governor `powersave` + EPP `balance_performance` is already doing the right thing — it races to 4.1 GHz, finishes the work, and drops back into CC6. On Zen that is usually *more* efficient than crawling at a low clock, because the fixed IOD and Infinity Fabric draw is paid for the whole time the core is awake either way.

`install.sh --status` deliberately does not print `scaling_cur_freq`. It prints the residency table instead, sampled as a delta over an interval rather than cumulatively since boot, which is the only honest answer to "is this thing downclocking".

## powertop can leave cores clamped at 603 MHz

Found on 2026-08-03, while checking something unrelated. Two of eight cores were pinned:

```
cpu0=603379  cpu1=5271622  cpu2=5271622  cpu3=603379
cpu4=5271622 cpu5=5271622  cpu6=5271622  cpu7=5271622
```

`powertop`'s binary contains write paths for `scaling_max_freq`, `scaling_min_freq` and `scaling_setspeed`, and it has a calibration mode (`-c`) that steps every core through its frequency range. All eight cores' `scaling_max_freq` carried the same mtime, to the millisecond — one writer looping over every CPU — and it fell inside an interactive `sudo powertop` session (`15:16:22` → `15:17:37`, write at `15:17:36`). It restored six and left two at the floor.

**Nothing warns you.** No error, no log line, no kernel message. Two of eight cores run at 603 MHz until the next reboot, and the symptom — a game stuttering for no apparent reason — arrives detached from the cause. It clearing on reboot makes it harder to catch, not easier.

So `--status` now compares every core's `scaling_max_freq` against `cpuinfo_max_freq` and warns. To fix without rebooting:

```sh
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh --restore-freq
```

That is deliberately not wired into `--install` or `--boot`: at boot the kernel builds the policy from `cpuinfo_*` and nothing has had a chance to clamp it, so a boot-time restore would guard a window that does not exist. The risk window is "someone just ran powertop", which is a manual event.

**Run `--status` after any powertop session.**

## What is applied

Two of powertop's ~45 suggestions. See [`sysctl.d/60-steam-machine-power.conf`](sysctl.d/60-steam-machine-power.conf) for the per-setting reasoning.

| Setting | From | To | Why |
| --- | --- | --- | --- |
| `kernel.nmi_watchdog` | 1 | 0 | Per-CPU perf counter that exists to detect hard lockups and panic. Kernel-debugging feature; on a console it costs a periodic NMI on all 8 cores and buys nothing anybody will read. |
| `vm.dirty_writeback_centisecs` | 500 | 1500 | Batches writeback, removing `wb_workfn` wakeups. Marginal here — the classic reason for this knob is letting a disk spin down, and the backing store is NVMe and zram. Cost is up to 15 s of unflushed dirty data on an unclean shutdown instead of 5 s. |
| SATA `link_power_management_policy` on all ahci hosts | `keep_firmware_settings` | `med_power_with_dipm` | HIPM down to Slumber plus DIPM, so the link drops to low power when idle. Applies to `host0`/`host1`, which carry the two MX500s. Set from [`udev.rules.d/`](udev.rules.d/60-steam-machine-power.rules) rather than a boot script, because hosts appear when `ahci` binds and a script would race that. |

`/etc/sysctl.d` and `/etc/udev/rules.d` are both **not** on the SteamOS keep list (verified against `/usr/lib/rauc/atomic-update-keep.conf` on 2026-08-03 — it contains no entry for either). Hence the `atomic-update.conf.d` entry and the boot self-heal, per the house pattern.

The self-heal re-applies both as well as restoring the files. `systemd-sysctl.service` runs at `sysinit.target` and the ahci hosts appear during early boot, both far earlier than this subsystem's unit can run — so on the first boot after an update that ate the files, restoring them alone would leave the settings inactive until the *next* reboot.

### Watch the SATA change

LPM interacts badly with a minority of SATA SSDs, producing `failed command: READ FPDMA QUEUED` and a link reset under load. Here that would land on a btrfs RAID1 holding the game library ([hardware/storage/](../../hardware/storage/README.md)), where it would look like filesystem trouble rather than a power setting. `--status` counts ATA exceptions and resets for the current boot for that reason. If the count is ever non-zero, revert first and diagnose after:

```sh
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh --uninstall   # restores max_performance live
```

Exercised on 2026-08-03 immediately after applying: a 256 MB write to the array, then three cycles of 15 s idle followed by an `iflag=direct` read, so the links actually entered slumber and had to come back rather than staying warm. `iodone_cnt` rose on both drives (the RAID1 write reached each), `ioerr_cnt` did not move from its pre-existing `0x5d`/`0x5e`, and there were no ATA exceptions, failed commands or link resets, with `btrfs device stats` all zero.

That is enough to say the drives negotiate LPM without immediately falling over. It is not enough to call it proven — the failure mode is intermittent and load-dependent, so the ATA counter in `--status` is the thing to keep an eye on over the next few weeks of real use.

## What was rejected, and why

This is the more useful half. Without it, the next person to run powertop re-derives the same 45 suggestions and re-applies the same ~40 useless writes.

### First: runtime PM demonstrably works on this box

Worth establishing before dismissing anything, because "powertop says Bad" and "this device cannot do runtime PM" are different claims. Snapshot of `/sys/bus/pci/devices/*/power/`, 2026-08-03:

| Device | Driver | `control` | `runtime_status` |
| --- | --- | --- | --- |
| `03:00.1`, `11:00.1`, `11:00.6` HD Audio | `snd_hda_intel` | `auto` | **suspended** |
| `11:00.3`, `11:00.4`, `12:00.0` xHCI | `xhci_hcd` | `auto` | **suspended** |
| `00:08.3`, `06:00.0`, `06:04.0`–`06:08.0` | `pcieport` | `auto` | **suspended** |

Eleven devices are actively runtime-suspended right now. So the mechanism is fine and the machine is not misconfigured wholesale — which is what a list of 41 "Bad" entries implies at a glance.

### The 41 entries are about four decisions

Powertop's check is `power/control != "auto"`. It is a string comparison; it does not test whether the device *can* do anything with `auto`. Grouping the entries by why they read `on`:

**~20 have no driver bound at all** — `00:00.0` Host bridge, `00:00.2` IOMMU, `00:01.0`/`02.0`/`03.0`/`04.0`/`08.0` Dummy Host Bridges, `00:14.3` LPC, and `00:18.0`–`00:18.7` Data Fabric (except `18.3`, which is `k10temp`). PCI runtime suspend is driven by the bound driver's PM callbacks; with no driver there is nothing to invoke, and every one of them sits at `active` while the driver-bound devices above reach `suspended`. Writing `auto` is harmless and does nothing.

**Four are one fact listed five times.** `0f:00.0` xHCI hosts `usb1` (six devices) and `usb2`; the Logitech receiver, DualSense, Turtle Beach headset and ITE controller all hang off it. A USB controller cannot runtime-suspend while a child device is pinned `on`. So `0f:00.0` and those four device entries are a single decision about the USB devices — and the sibling controllers `11:00.3`/`11:00.4`/`12:00.0`, which have only root hubs, are already `auto` and suspended. That is the control group.

**The audio one is simply wrong.** Powertop asks for `power_save` = `1`; it is `10`, with `power_save_controller` = `Y`. Its check compares against the literal string. The proof it is already working is in the table above: all three `snd_hda_intel` functions are suspended.

**The SATA entries were the real ones**, and are now applied — see the table further up. `host0` = `sda`, `host1` = `sdb`, both at `keep_firmware_settings`; `host4`/`host5` are the empty ports, already at `med_power_with_dipm`. Do not guess this mapping — it is the reverse of what the host numbering suggests, and guessing it wrong once is what made `--status` print `/sys/class/scsi_host/host*/device/target*/*/block/*` on every run.

### Rejected on risk

- **USB autosuspend on the Logitech Unifying receiver (`1-1`), the DualSense (`1-7`) and the Turtle Beach headset (`1-4`).** Dropped first keypress, input lag on wake, audio pop. Not on a machine whose entire job is games. This is also what keeps `0f:00.0` at `on`, so accepting that controller entry as permanent is part of the same decision.
- **USB autosuspend on the GIGABYTE ITE device (`1-8`, `048d:5711`).** This one looks safe — nothing latency-sensitive polls it — and it is not. That is the IT5711 RGB Fusion controller that [hardware/rgb/](../../hardware/rgb/README.md) writes to over hidraw to keep every LED off, and ITE controllers are known to revert to their hardcoded rainbow when the USB device suspends. Sub-watt gain against the LEDs coming back on in the living room.
- **Runtime PM on the NVMe (`0000:04:00.0`).** It holds `/`, `/var` and `/home` — never idle long enough to matter — and d3cold on DRAM-less drives has a track record of hangs.
- **Runtime PM on the RTL8125 (`0000:09:00.0`).** Link is up, so it will not suspend — and Wake-on-LAN is armed on it ([hardware/network/](../../hardware/network/README.md)), which is not worth disturbing for a device that would stay `active` anyway.
- **Runtime PM on the SMBus controller (`00:14.0`, `piix4_smbus`) and `00:18.3` (`k10temp`).** Both are driver-bound and therefore real candidates, unlike the rest of the `00:18.x` block. Left alone because [hardware/sensors/](../../hardware/sensors/README.md) reads DIMM temperatures over that SMBus and CPU temperature from `k10temp`; suspending either to save milliwatts would undermine the thermal logging this machine was set up to do.
- **Runtime PM on the iGPU (`11:00.0`, `amdgpu`).** Driver-bound and idle, so superficially the best remaining candidate. `amdgpu` only enables runtime PM where it can power-gate the whole device (`_PR3`/BOCO, i.e. hybrid-graphics laptops); on a desktop APU alongside a discrete card it has no such path, and gamescope, Steam and LACT all hold `renderD129` open regardless. Writing `auto` would be a no-op with a small chance of being worse than one.
- **Runtime PM on the CCP (`11:00.2`).** Crypto co-processor, already idle, no measurable draw.
- **ASPM `powersupersave`** (currently `default`, i.e. firmware-controlled). Latency risk on the GPU and NVMe for a couple of watts.
- **Dynamic EPP switching** (`power` at idle, `balance_performance` on game launch). Deferred, not dismissed: the CPU already idles in C3 93% of the time and race-to-idle means a lower clock may not save energy at all. Wants a wall-meter baseline before it earns its moving parts. `--status` reports the live EPP so the experiment is easy to start.

## The lever that is not in here

The dGPU idles at 6–7 W, which is about as low as a 9070 XT goes. `mclk` is pinned to its top bin (1258 MHz) because 4K120 with DSC needs the bandwidth — inherent to the mode, not tunable.

Against that, a suspended machine draws close to nothing. **Suspend-vs-idle is worth more than every setting on this page combined**, which makes [hardware/sleep/](../../hardware/sleep/README.md) the real idle-power subsystem. Its keep-awake grace window was cut from 7200 s to 1800 s on 2026-08-03 for exactly this reason: the journal showed only two suspends in three days, because a two-hour tail after every SSH session meant daily remote work kept the box awake essentially permanently.

`--status` prints any held `block` inhibitor for this reason — if the machine is not sleeping, that is the first thing to look at, not the sysctls.

## Verifying it survived

```sh
./install.sh --status
```

After an A/B update, `journalctl -u steam-machine-power` shows whether the self-heal had to put anything back.
