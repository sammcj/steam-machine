# DIY Steam Machine Scripts & Helpers

- [TODO](#todo)
- [Working (done)](#working-done)
  - [Not working (yet)](#not-working-yet)
- [Hardware](#hardware)
- [Platform notes](#platform-notes)
  - [After a SteamOS update: one command](#after-a-steamos-update-one-command)
  - [SteamOS persistence](#steamos-persistence)
  - [SMT is off in the BIOS](#smt-is-off-in-the-bios)
  - [SMBus and I2C on AM5](#smbus-and-i2c-on-am5)
  - [Display: 4K120 over HDMI (amdgpu)](#display-4k120-over-hdmi-amdgpu)
  - [Onboard wireless (MediaTek MT7902)](#onboard-wireless-mediatek-mt7902)

## TODO

Things I haven't got around to investigating or doing yet
Priorities below are (H)igh, (M)edium, (L)ow.

- **Turn SMT back on in the BIOS (M)** - the 9800X3D is 8C/16T and is currently running 8C/**8T**. `Thread(s) per core: 1`, `/sys/devices/system/cpu/smt/control` = `notsupported`, `thread_siblings_list` = `0`, and there is no `nosmt` on the kernel command line, so it is off at firmware level rather than anything software-side. Gigabyte's default is Auto (enabled), so this was either changed deliberately or reset. **Advanced → AMD CBS → SMT Control → Auto**. Costs roughly 25-40% on compile-bound work; near-neutral for gaming. See [Platform notes](#smt-is-off-in-the-bios).
- Configuration backup (M)
- Emulation setup (setup retrodeck, restore rooms and metadata from SteamDeck) (L)
- Overclocking GPU (L) - the _controls_ are now available and persistent (LACT overdrive, see [hardware/gpu/](hardware/gpu/README.md)); no clocks, limits or fan curves have actually been set yet.
- DualSense adaptive triggers (not sure if they work / how to configure them) (M)
  - https://github.com/egormanga/SAxense
  - https://hardwaretester.com/gamepad
  - https://github.com/awalol/DS5Dongle (this looks cool!)
    - https://ds5-dev.awalol.eu.org/
- Cloud Saves for non-Steam games (L)
- Investigate if I can extract saves from a few games on my PS5 (Blue Prince for example) and copy them to SteamOS (L)
- Setup video streaming clients (Plex, Jellyfin, ABC iView, SBS On Demand, Netflix etc.) (L)

## Working (done)

- Enabled TRIM (disacard) in fstab
- Set noatime in fstab
- **Onboard Bluetooth (MediaTek MT7902)** - working via an out-of-tree `btusb_mt7902` driver. `hci0`, BlueZ default controller, survives reboots and SteamOS A/B updates. See [hardware/bluetooth/](hardware/bluetooth/README.md). The USB dongle is no longer needed but is worth leaving in as a fallback.
- **Hardware sensors** - full coverage for thermal logging: fan RPM / Vcore / VRM temp from the ITE IT8696E (out-of-tree `it87`), SATA SSD temps (`drivetemp`), and the FCH SMBus unblocked so DDR5 DIMM temps work. All labels verified by correlation under load, not guessed. See [hardware/sensors/](hardware/sensors/README.md). DIMM temps confirmed reading after the reboot.
- **Secondary game library (BTRFS RAID1)** - the two Crucial MX500s mirrored and mounted at `/home/deck/SATA` via fstab, with `compress=zstd:1`, `discard=async`, `noatime`, monthly scrub and weekly trim. SteamOS's own automount refuses anything that isn't ext4, so this goes around it. See [hardware/storage/](hardware/storage/README.md). **One manual step left:** register it as a Steam library with Steam closed.
- **CoolerControl** - daemon + embedded web UI on port **11987** for watching temps, fans and power over time, reading the hwmon coverage above. Reachable from the LAN, not just localhost. It never touches the fan curves (`apply_on_boot = false`, so they stay with the BIOS), but the API itself is read/write behind a single password - CoolerControl has no read-only mode. **Off by default**: it is a LAN-exposed root daemon polling hwmon continuously, so it is turned on per measurement session with the `coolercontrol on` / `coolercontrol off` shell function ("on" persists across reboots, so you can enable it and reboot into gaming mode). See [hardware/coolercontrol/](hardware/coolercontrol/README.md).
- **4K 120Hz over the native HDMI port** - working (2026-08-06) on a hand-built mainline **Linux 7.2** (`7.2.0-frlprobe`; 7.2-rc6 until the 21 August rebase) with HDMI 2.1 FRL enabled (`amdgpu.dcfeaturemask=0x402`). **3840×2160 @ 120 Hz, RGB 4:4:4, 12 bpc, uncompressed, HDR10, `underflow 0`, single pipe** - measured at a 1188.00 MHz pixel clock, 1.98× the 600 MHz HDMI 2.0 TMDS ceiling. Strictly better than the converter it replaces (10 bpc *with* DSC, plus glitching), and the adapter is out of the chain. Verified rather than assumed that no Valve kernel can do this: `amdgpu.ko` extracted from 6.16.12, 6.18.33 and 6.18.38 all have a byte-identical FRL symbol set, and none contain the native `dcn401_hpo_frl_stream_encoder`. See [hardware/kernel/](hardware/kernel/README.md), with the raw capture in [`frl-4k120-evidence.txt`](hardware/kernel/frl-4k120-evidence.txt). It is now the **default boot entry** and **survives SteamOS updates**: a keep-listed systemd unit restores it from a cached tarball on `/home` after an image swap, at a cost of one boot on the stock kernel. `grub.cfg` stays byte-for-byte stock, so a failure anywhere in this falls through to Valve's kernel. **VRR works too** (2026-08-06): 40-120 Hz, `vrr_capable 1`, via AMD's unmerged 4-patch series hand-ported onto the build - see [hardware/kernel/patches/](hardware/kernel/patches/). CEC does not work: amdgpu registers no CEC adapter for its own HDMI ports on any kernel. **Power-off hangs are fixed** (2026-08-08) - they needed two changes, an `mt7921e` blacklist and a shutdown-time VT switch.
- **4K 120Hz via a DP converter** - *superseded by the above, kept because it still works and is the fallback.* Working 2026-08-02 via a **UGREEN 80397** active DP 1.4 → HDMI 2.1 converter on `DP-1`, immediately on hotplug with no configuration. 4:4:4 10-bit with HDR, DSC active, `underflow 0`. See [hardware/display/](hardware/display/README.md). VRR does not work through this converter and is not being chased - see below.
- **"No signal" when the TV is switched on after the machine** - the converter is the DP sink, not the TV: it holds HPD asserted and answers EDID from cache whether the TV is on or off, so a modeset landing while the TV is off strands it forever, with every driver-side reading claiming a healthy 4K120 link. Nothing on this side can detect the TV's power state - DPCD, DDC, DDC/CI and the audio ELD were all sampled across a power cycle and are bit-identical, so a polling daemon has nothing to poll. Fixed by forcing a replug through debugfs `trigger_hotplug`, wired to four triggers: **Shift+Esc**, controller connect, boot and resume. See [hardware/display/](hardware/display/README.md).
- **GPU overdrive (LACT) made persistent** - LACT's "enable overclocking" writes `/etc/modprobe.d/99-amdgpu-overdrive.conf`, which is *not* on the SteamOS keep list, so every A/B update silently deletes it and every LACT control goes back to greyed-out. Confirmed by recovering the file from the `/etc` snapshot the 1 Aug update took just before discarding it. Now allowlisted, with a boot self-heal. See [hardware/gpu/](hardware/gpu/README.md). Confirmed active after the reboot: `--status` reports the overdrive bit set.
- **Sleep during remote sessions, and the Steam client wedge it caused** - a root daemon used to hold a logind `block` inhibitor on `sleep` while any sshd session existed, so the machine could not suspend out from under an SSH shell. **Removed 2026-08-18.** It did not postpone suspends, it cancelled them, and it wedged Steam on the way past: Steam sets an internal "suspend in progress" flag and tears its UI down *before* calling `Manager.Suspend`, and when logind refuses it never unwinds - the flag stays set (`SuspendResume: Ignoring suspend request while a suspend operation is in progress: 1`), the library and store stay blank, and only restarting the client clears it. Steam's idle-suspend is also one-shot, so the refusal consumed that idle period's only attempt and the machine then sat awake for 24 hours. Diagnosed from a *refused* suspend (`AccessDenied ... active block inhibitor`) with no matching `CCMInterface::OnSystemPowerStateSuspend` - the networking layer is never told, which is why the client stays logged on with a healthy hourly heartbeat while its UI is dead. The `SteamUI thread frame stalled` warnings in `steamui.txt` are unrelated and were the first, wrong explanation. Nothing replaced it; `system/ssh/`'s keepalives still stand on their own. See [hardware/sleep/](hardware/sleep/README.md).
- **sshd policy pinned, and keepalives enabled** - `/etc/ssh/sshd_config.d/10-steam-machine.conf` was tracked nowhere and pinned by nothing; the keep list covers `/etc/ssh/*_key` and nothing else, so `AllowUsers deck` and `PermitRootLogin no` would have silently reverted to stock Arch defaults on the next A/B update - a quiet loosening of access policy with no symptom at all. Now in the repo, allowlisted, with a boot self-heal that validates via `sshd -t` and rolls back rather than risking a lockout. Also sets `ClientAliveInterval 60` / `ClientAliveCountMax 5`: with keepalives off (the default) a dropped client leaves its session registered with logind for up to ~2 h 11 m of TCP timeout, which would pin the machine awake through the inhibitor above. The two are a pair. See [system/ssh/](system/ssh/README.md).
- **tmux sessions dying on every SSH disconnect** - reconnecting from a phone after its screen slept found no server at all, not a detached session. `jupiter-legacy-support` ships `/etc/systemd/logind.conf.d/killuserprocesses.conf` with `KillUserProcesses=True`, so logind kills the whole `session-N.scope` when a login ends - and a tmux server started by an SSH shell is inside it. Nothing to do with tmux config, and detaching first makes no difference: the kill is by cgroup. Fixed by starting the server from a systemd *user* unit, which puts it in `user@1000.service/app.slice` where no session scope owns it, plus a `tmux` shell wrapper that starts that unit on demand and linger so the user manager stays up with nobody logged in. Valve's cleanup is left on rather than disabled with `KillExcludeUsers=deck`, which would turn it off machine-wide for the only real user. The unit is deliberately **not** enabled - started at boot it would predate the Plasma session's `DISPLAY`/`WAYLAND_DISPLAY`, and hold that empty environment for its whole life, breaking `sudo -A` askpass in every pane. See [system/tmux/](system/tmux/README.md).
- **Idle power** - `powertop` was run because the CPU appeared pinned at 4 GHz+ at idle. It is not: `scaling_cur_freq` and `/proc/cpuinfo` both derive from APERF/MPERF, which on AMD only tick in C0, so they report the clock during the awake slices and are blind to halted time. Measured residency is 93% idle (77% in C3), and `amd-pstate-epp` is already doing the right thing by racing to clock and dropping back into CC6. Of powertop's ~45 suggestions three survived triage: `kernel.nmi_watchdog=0`, `vm.dirty_writeback_centisecs=1500`, and SATA `med_power_with_dipm` on the two MX500s. Its 41 "Bad" runtime-PM entries reduce to about four decisions - ~20 are PCI devices with no driver bound, so `auto` has nothing to invoke; five are the single fact that one xHCI controller cannot suspend while the controllers and headset plugged into it are pinned on; one is a powertop bug (it string-compares `snd_hda` `power_save` against "1" when the value is "10" and all three codecs are already suspended). Every rejection is recorded with its evidence so the next powertop run doesn't re-derive them. See [system/power/](system/power/README.md).
- **Journal retention too short to diagnose an overnight fault** - `journalctl --list-boots` reported a single boot, which read as "logs are in RAM" and is not the problem: SteamOS ships `Storage=persistent` and `/var/log` is a bind onto `nvme0n1p8` with 753 GB free. The cap is what is short - `/usr/lib/systemd/journald.conf.d/system-max-use.conf` sets `SystemMaxUse=50M`, and at this machine's measured ~23 MB/day that is about two days, so anything noticed the following evening has already been vacuumed. Now a week, via a drop-in setting `MaxRetentionSec=1week` with `SystemMaxUse=512M` as a backstop. The filename does the work: systemd sorts drop-ins by name across all directories and the last one wins, so a conventional `99-` prefix would have **lost** to Valve's `system-max-use.conf` (`9` sorts before `s`) and been silently overridden by the setting it replaces - hence `zz-`, and a `--status` that reads the merged config back and names the winning file rather than checking our own. See [system/journal/](system/journal/README.md).
- **RGB lighting off, and staying off** - motherboard (ITE IT5711) and Kingston FURY DDR5 both blanked via OpenRGB **Static**, which commits to the controller and survives a power cycle. The DIMMs were never an OpenRGB gap but an ACPI one: `acpi_enforce_resources=strict` made `i2c-piix4` register **zero** adapters. The stock `/usr/lib/udev/rules.d/60-openrgb.rules` is owned by no package and grants uaccess to *every* i2c bus including the SMBus with the always-writable SPD EEPROMs; replaced by a narrow rule in `/etc`. See [hardware/rgb/](hardware/rgb/README.md). Only the GPU shroud strip is left - see below.
- **2026 Steam Controller on a mainline kernel** - Valve's `hid-steam` backported onto mainline 7.2 as [patches 0007-0008](hardware/kernel/patches/README.md); all nine puck interfaces bind it and `/dev/input/js*` appears. It is **not upstream** — nothing referencing IBEX/PROTEUS/NEREID exists in public kernel git, and the only public copy is inside a 3.5 GB SteamOS source package. Valve's 6.18 driver compiles against 7.2-rc6 unmodified, so those two patches are all any mainline kernel needs.
- **Shell setup in the repo** - the aliases and `PATH`/env exports that were only ever in `~/.bashrc`: `g`/`p`/`P`/`gitwip`, the `cc`/`ccd`/`cccd`/`ccrd` Claude Code aliases, `vi`, and the Homebrew / `~/.local/bin` / `.NET SDK` `PATH` setup. Sourced from the repo rather than copied, so the version under git is the one actually in use. `trigger_detect_tv` was the one machine-specific alias and was stale - it wrote to a hardcoded `dri/0/DP-1` path; it now calls `display-redetect`, the same script the four automatic triggers run. The subsystem-specific shell functions (`keepawake`, `wayland`, `coolercontrol`) stay with their own hardware. See [system/shell/](system/shell/README.md).
- **input-remapper** - keyboard/mouse/controller remapping, 2.2.1, installed to `/opt/input-remapper` and surviving SteamOS A/B updates. Its README reads as if it needs building against the kernel; it does not - there is no module and no DKMS, just `/dev/uinput` via `python-evdev`, and **nothing is compiled** (this machine has no `gcc`, `make` or `linux/input.h`). SteamOS already ships every dependency that would need a compiler; the one gap, `gtksourceview4`, is unpacked from Valve's Arch mirror into the prefix rather than pacman'd. Installed upstream's way it would vanish on the next update with no error at all - its installer writes only to `/usr` and scores `/home` site-packages at -50 - so the app lives in `/opt` (offload mount, survives updates) and only five path-pinned files are self-healed: four `/usr/bin` entry points, the hardcoded `/usr/share/input-remapper` DATA_DIR (a symlink), the polkit action, plus a keep-listed system-bus policy and udev rules. Daemon running, devices enumerating. **Not tested in Game Mode** - the GUI is GTK3 and needs the Desktop session. See [system/input-remapper/](system/input-remapper/README.md).
- **sudo password caching** - every `sudo` used to re-prompt, and with no tty to prompt in that meant a ksshaskpass dialog on the TV per command. Not the timeout: sudo's default `timestamp_type=tty` has nothing to key on without a terminal and falls back to the **parent pid**, which is different for every shell, so the record could never match. Now `Defaults:deck timestamp_type=global` with a 15-minute timeout, keep-listed (`/etc/sudoers.d` is not on the SteamOS keep list) and installed behind a `visudo` validate-and-rollback so a bad file cannot lock the machine out of root. The trade - any `deck` process can sudo unprompted for the window - is taken deliberately and written down. See [system/sudo/](system/sudo/README.md).

### Not working (yet)

#### Controller wake from sleep (H)

- Wake from a Bluetooth controller does not work (PlayStation 5 DualSense).
- An upstream report says the 2026 Steam Controller and its puck also fail to wake from suspend ([bazzite#4873](https://github.com/ublue-os/bazzite/issues/4873)) — **not tested here**, noted because it is the same item.

#### VRR through a DP→HDMI converter (L)

Native HDMI FRL has VRR, so this only matters if the converter ever comes back into the chain.

Both converters tried here are the **same Chrontel CH7218** (`branch_dev_id 0x2B02F0`), and `amdgpu` needs three conditions to pass VRR through a converter. Two are met — `ADAPTIVE_SYNC_SDP_SUPPORT` (DPCD 0x2214 bit 0) and `allow_invalid_MSA_timing_param` (DPCD 0x007 bit 6). The third is a hardcoded five-OUI whitelist that `0x2B02F0` is not in, so **the whitelist is the only unmet condition**. A one-line kernel patch is a real if unproven shot, against the counter-evidence that bypassing it on Valve 6.16 delivered nothing. `freesync_pcon_allow_all` does not exist on mainline 7.2-rc6, so a source patch is the only route.

Measurements and the full three-way comparison: [`hardware/display/4k120-paths.md`](hardware/display/4k120-paths.md).

#### HDMI CEC on the native port — never (M)

Not a driver gap: **the silicon has no CEC controller.** AMD's register headers in the 7.2-rc6 tree contain zero `CEC` macros across every DCN generation (1.0 → 4.1.0), and the DCE-era headers have one read-only pinstrap bit that no kernel code reads. `amdgpu.ko` imports only `cec_notifier_*` (publishes the physical address *for* someone else's adapter) and `drm_dp_cec_*` (the DisplayPort tunnel); the adapter-registration API is absent entirely, so there is no `/dev/cec*` to attach to. Whether HDMI pin 13 is wired is moot.

**CEC does work over a DP→HDMI converter** (confirmed 2026-08-10) — that is what "CEC works on my 9070 XT" reports actually are. See the [Working](#working-done) entry.

#### RGB: XFX GPU shroud strip (L)

The board and the DIMMs are blanked and stay blanked; only the graphics card's strip is outstanding, and it is a cabling job rather than a software one.

The card has **no RGB controller** — all six of its I²C buses are empty and nothing on USB/hidraw belongs to it, which is why OpenRGB can never see it as a GPU ([upstream #5154](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/5154) is this exact card, with a blank captures section). The shroud strip is a dumb 5V ARGB slave with an input connector; unconnected it runs a hardcoded rainbow from a small onboard driver, which is what makes it look software-reachable.

**Fix: plug the supplied XFX sync cable into one of the board's three ARGB_V2 headers**, at which point the strip becomes a zone of the IT5711 controller OpenRGB already drives. [hardware/rgb/](hardware/rgb/README.md) already sizes and blanks all three headers, so it does not matter which is used. **Pending: cable not yet connected.**

#### Onboard WiFi (L)

Unsupported and deliberately blacklisted — mainline 7.2 binds the device but MediaTek have never published its firmware, and the driver's remove path then hangs power-off. Not worth chasing while 2.5G wired works. Bluetooth on the same chip **does** work; see the [platform note](#onboard-wireless-mediatek-mt7902).

---

## Hardware

Initial purchase (2026-08-01)

| Product                                                    | SKU / Part          | Cost (AUD) (inc GST) |
| ---------------------------------------------------------- | ------------------- | -------------------: |
| AMD Ryzen 7 9800X3D Desktop Processor                      | 100-100001084WOF    |              $648.00 |
| Biwin Black Opal NV7400 2TB M.2 2280 NVMe 2.0 PCIe 4.0 SSD | BNV740002TB-RGX     |              $399.00 |
| Corsair SF Series SF850 850W Power Supply                  | CP-9020256-AU       |              $269.00 |
| Corsair NAUTILUS 360 RS Black 360mm Liquid CPU Cooler      | CW-9060089-WW       |              $129.00 |
| Gigabyte B850M FORCE WIFI6E V2 Motherboard                 | B850M FORCE WF6E V2 |              $179.00 |
| Kingston FURY RGB Black 32GB (2x16GB) 6000MHz DDR5         | KF560C36BBE2AK2-32  |              $699.00 |
| Lian Li DAN-A3 Beech Wood Edition Micro ATX Case           | PC-A3W-WD           |              $129.00 |
| Ugreen 3M 8K UHD HDMI 2.1 Male to Male Cable               | 80404               |               $24.00 |
| XFX Mercury Radeon RX 9070 XT OC Gaming Edition, 16GB      | RX-97TRGBBB9        |            $1,099.00 |
| Card Surcharge                                             |                     |               $35.75 |
| **Grand total**                                            |                     |        **$3,610.75** |

Other parts

| Product                                    | SKU / Part | Cost (AUD) (inc GST) |
| ------------------------------------------ | ---------- | -------------------: |
| Playstation 5 DualSense (already had)      |            |                $0.00 |
| Steam Controller (2026) + wireless puck    |            |              $270.00 |
| Turtle Beach Headset (already had)         |            |                $0.00 |
| TV - LG OLED C9 75" 4K 120Hz (already had) |            |                $0.00 |
| Crucial 2TB SATA SSDs x2                   |            |                $0.00 |
| DisplayPort 8K 240Hz to HDMI 2.1 Cable     | 80397      |               $24.00 |

Links:

- https://www.scorptec.com.au/product/graphics-cards/amd/116057-rx-97trgbbb9
- https://www.scorptec.com.au/product/cases/micro-atx/112747-pc-a3x-wd
- https://www.scorptec.com.au/product/memory/ddr5-desktop-memory/113814-kf560c36bbe2ak2-32
- https://www.scorptec.com.au/product/motherboards/amd-socket-am5/123608-b850m-force-wf6e-v2
- https://www.scorptec.com.au/product/cooling/cpu-coolers/114722-cw-9060089-ww
- https://www.scorptec.com.au/product/power-supplies/rackmount-slim/110637-cp-9020256-au
- https://www.scorptec.com.au/product/hard-drives-and-ssds/solid-state-drives--ssd/126628-bnv740002tb-rgx
- https://www.scorptec.com.au/product/cpu/amd-socket-am5/114321-100-100001084wof

---

## Platform notes

Measured on this machine unless a line says otherwise.

### After a SteamOS update: one command

Every subsystem installs a systemd unit that runs its own `install.sh --boot` at each boot, so an A/B update repairs itself with no intervention. The top-level `install.sh` does the same thing *now*, in one place, with the output in front of you — which is what you want straight after an update rather than rebooting and hoping:

```bash
sudo ./install.sh            # restore everything a SteamOS update removed
sudo ./install.sh --status   # report every subsystem, change nothing
./install.sh --list          # which subsystems support which modes
```

It runs `hardware/kernel` first, because that restores `/usr/lib/modules` for the FRL kernel and the out-of-tree modules (`it87`, `btusb_mt7902`) need a module tree that already exists. A failing subsystem does not stop the others — after an OS update, "fifteen of seventeen restored, here are the two that did not" beats aborting on the first problem — and the script exits non-zero if any failed.

Note the first boot after an update lands on the **stock Valve kernel**: the update replaces the EFI partition wholesale, taking `custom.cfg` with it. That is deliberate, not a fault. Run the command above, reboot, and you are back on the FRL kernel.

### SteamOS persistence

SteamOS 3.x boots a read-only btrfs root from an A/B pair. An update writes a whole new image to the inactive slot and boots into it, so anything in `/usr`, `/opt` or `/usr/local` is gone after the next update. That includes anything `pacman -S` installed after `steamos-readonly disable`.

**Btrfs confirmed** (`findmnt -no SOURCE,FSTYPE /`). The active slot changes with every update — it is `/dev/nvme0n1p4` after the 8 Aug one, having been `p5` before — so never hardcode the partition. `steamos-readonly status` reports **enabled** again after an update even if it was disabled beforehand, which is why every installer here unlocks and relocks around its own writes rather than assuming.

- `/home` - separate partition, always survives.
- `/etc` - overlayfs with its upper layer in `/var/lib/overlays/etc/upper` (confirmed via `findmnt /etc`). Survives reboots always, and is writable even when `steamos-readonly` is enabled. Since SteamOS 3.6 only an allowlisted subset carries into a new OS version.
- `/etc/atomic-update.conf.d/` - the supported way to add paths to that allowlist, and it has to name the `systemctl enable` symlinks too, not just the unit files. Read `example-additional-keep-list.conf` on the machine for the syntax; it is not documented publicly.
- **The default keep list is `/usr/lib/rauc/atomic-update-keep.conf`** - read it before assuming anything in `/etc` persists across an update. It covers `/etc/systemd/system/*.service`, `*.socket`, `*.mount`, `*.wants/**`, `*.requires/**`, NetworkManager connections, sddm.conf.d, ssh host keys, passwd/group/shadow and `/etc/atomic-update.conf.d/*.conf` itself (so allowlist entries are self-preserving).
- **`/etc/modprobe.d` is _not_ on that list**, nor is `/etc/modules-load.d` or `/etc/default/grub*`. Anything dropped there needs its own `atomic-update.conf.d` entry or it vanishes on the next A/B update, silently and with no obvious symptom.
- **This bites third-party tools that write to `/etc` on your behalf, not just things set up here.** LACT's "enable overclocking" button writes `/etc/modprobe.d/99-amdgpu-overdrive.conf` and is otherwise correct; the 1 Aug 2026 update ate it, and the only symptom was LACT offering to enable overclocking again. Assume any tool that offers to write a `/etc` file needs checking against the keep list. Now handled by [hardware/gpu/](hardware/gpu/README.md).
- **`/var/lib/steamos-atomupd/etc_backup/*.tar.xz` is how to prove it after the fact.** SteamOS snapshots `/etc` immediately before discarding it, so `tar tf` on the newest tarball lists exactly what the last update took. This is the fastest way to answer "did this get wiped, or did I never set it?". Allowlist the *specific file*, never the directory - an allowlisted path shadows all future upstream versions of it forever. The one exception is a directory nothing upstream ships into and no pacman package owns, where there is no version to shadow: `/etc/coolercontrol/*` is allowlisted wholesale for exactly that reason, because the daemon creates its own state files there and naming them individually would silently lose any a future release adds.
- Don't edit `/etc/default/grub-steamos` to add kernel parameters: it is a Valve-shipped file in the overlay's lower layer, so editing it permanently shadows their future GPU/platform tuning. `grub-mkconfig` sources `/etc/default/grub.d/*.cfg` first (line 163 of the script), which is the clean place for additions. Better still, if the setting is a module parameter, use `/etc/modprobe.d` - no `grub.cfg` regeneration needed.
- Prefer solutions with no package dependencies. Python 3 is in the base image. `i2c-tools` is not.
- Anything installed with pacman needs an idempotent install script that gets re-run after every OS update.
- `/usr/lib/systemd/system-sleep/` is unusable here (read-only rootfs). For resume hooks use a systemd unit in `/etc/systemd/system` with `After=sleep.target` and `WantedBy=sleep.target`. `sleep.target` covers suspend, hibernate, hybrid-sleep and suspend-then-hibernate; `suspend.target` only covers plain suspend.

### SMT is off in the BIOS

Measured 2026-08-08 during a kernel build, and worth knowing before trusting any benchmark taken on this machine:

```
Model name:          AMD Ryzen 7 9800X3D 8-Core Processor
Thread(s) per core:  1                 <- 2 expected
CPU(s):              8                 <- 16 expected
smt/control          notsupported      <- firmware, not a kernel setting
thread_siblings_list 0                 <- core 0 has no sibling
```

`notsupported` means the kernel never enumerated a second thread per core, and `/proc/cmdline` carries no `nosmt` or `maxcpus`, so this is the firmware and not something fixable from the OS.

The effect is workload-shaped: a kernel `make modules` is entirely `cc1`, which is branchy and cache-missy and therefore exactly what SMT fills stalls for - expect 25-40% back. Games are near-neutral, sometimes marginally better with it on. Nothing here is broken by it; it just quietly halves throughput on anything that scales with threads, and any CPU benchmark in these notes taken before it is fixed is measuring 8 threads, not 16.

### SMBus and I2C on AM5

- **The SMBus is blocked by ACPI out of the box, and this is the reason a tool "doesn't detect" RAM on this board.** The firmware declares an OperationRegion (`\GSA1.SMBI`) over `0x0B00-0x0B0F`, and the kernel default `acpi_enforce_resources=strict` makes `i2c-piix4` back off rather than share it: the module loads and registers **zero** adapters. Boot with `acpi_enforce_resources=lax` to get them. Installed by [hardware/sensors/](hardware/sensors/README.md); it is a boot parameter only, not settable at runtime.
- Once it works, `i2c-piix4` registers **several** adapters (`SMBus PIIX4 adapter port N at 0bXX`). Only one carries the DIMMs.
- To find that port without generating any bus traffic, list what the SPD driver bound: `ls /sys/bus/i2c/drivers/spd5118/` returns entries like `0-0050`, `0-0051`, where the prefix is the bus number. Kernel patches from mid-2024 auto-instantiate `spd5118` on the correct piix4 port, so this is authoritative rather than a guess. Anything else on the DIMMs, including the Fury RGB controllers at `0x60-0x67`, is on that same bus.
- `i2c-dev` ships in the kernel but is not auto-loaded, and is **deliberately left unloaded** - without `/dev/i2c-*` no userspace tool can reach the bus at all, which is a free extra layer between the SPD hubs and a stray `i2cdetect`. Anything that needs it (OpenRGB) should opt in explicitly, as its own decision.
- **This platform has no hardware SPD write protection.** Intel's `i2c-i801` honours an SPD write disable bit in the SMBus host config register (`SMBHSTCFG_SPD_WD`) that BIOS can set, blocking host writes to `0x50-0x57` in hardware. `i2c-piix4` has no equivalent and calls `i2c_register_spd_write_enable()` unconditionally. The DDR5 SPD EEPROMs here are always writable from the host, so any tool that scans or writes SMBus can kill the RAM. This is why the RGB plan is as paranoid as it is.
- `spd5118` (hwmon) binds the DDR5 SPD hubs at `0x50-0x57`. While bound, `ioctl(I2C_SLAVE)` on those addresses returns `EBUSY`, and that is the main thing protecting them. Never unbind it. `i2cdetect` prints `UU` for addresses a driver owns.
- On DDR5 the module temperature sensor lives **inside** the SPD hub, so anything reading DIMM temps is talking to `0x50-0x57`. Through the `spd5118` driver that is fine. Through a userspace tool on `/dev/i2c-*` it is not.
- Never run `i2cdetect -y <bus>` bare: its auto mode quick-writes to every address outside `0x30-0x37` and `0x50-0x5F`. Restrict it, and force read-byte probes: `i2cdetect -y -r <bus> <first> <last>`.
- `dmidecode -t 17` enumerates the DIMMs with zero bus traffic. Keep a baseline of its output; a change in reported size, speed, part number or serial is the early warning that SPD has been corrupted.

### Display: 4K120 over HDMI (amdgpu)

Current state and measurements: [hardware/kernel/](hardware/kernel/README.md) for native FRL, [`hardware/display/4k120-paths.md`](hardware/display/4k120-paths.md) for the FRL-vs-converter comparison. What is kept here is only what is not obvious from either.

> **The TV is this machine's only console.** An unsyncable mode is a black screen with no way to type the fix, which happened during this work. Arm a revert timer before any experimental modeset - `(sleep 20; kscreen-doctor output.<out>.mode.<safe-idx>) &`.

**Why a SteamOS kernel cannot do 4K120 over HDMI.** Not the cable or the TV — the C9 advertises `VIC 118` and FRL up to 12 Gbps/lane. The HDMI Forum rejected AMD's open-source HDMI 2.1 implementation in 2023-24, leaving `amdgpu` capped at HDMI 2.0's **600 MHz TMDS character rate**; 4:4:4 4K120 needs 1188 MHz. FRL merged for Linux 7.2 and is **off by default**. Valve backported the ALLM/HDMI-VRR half but not FRL.

**The enabling parameter is widely misquoted online** as `amdgpu.dc_feature_mask=0x400`. Both parts are wrong: it is spelled `dcfeaturemask`, and it *replaces* the mask rather than OR-ing into it — the live value here is `2`, so it needs `0x402`.

**Desktop mode is X11 or Wayland depending on how you enter it**, and X11 has no colour management, so wide-gamut content goes to the OLED unmanaged and badly over-saturated with the HDR/WCG/ICC controls missing from KDE entirely. Steam's Power → Switch to Desktop hardcodes X11; booting to desktop gives Wayland. Fix the current session with `steamos-session-select plasma-wayland`.

**4:2:0 was tried and rejected.** It needs a one-byte EDID patch (ext block byte 93, `0x33`→`0x3f`) *plus* `force_yuv420_output=1`, and is 8-bit only — soft text, banded HDR.

### Onboard wireless (MediaTek MT7902)

This board uses a **MediaTek MT7902** (Filogic 310, Wi-Fi 6E + BT 5.3), not the MT7922/MT7925 that most Gigabyte AM5 boards ship. Both functions are now **confirmed on-machine**:

- WiFi is the PCIe function: `lspci -nn | grep -i net` → `08:00.0 Network controller [14c3:7902]`.
- Bluetooth is a **separate USB device** on MediaTek's own vendor ID: `lsusb` → `Bus 001 Device 005: ID 0e8d:7902 MediaTek Inc. Wireless_Device`.

Why neither worked out of the box (**Bluetooth is now fixed** - see
[hardware/bluetooth/](hardware/bluetooth/README.md); WiFi is unsupported and blacklisted):

- **WiFi - unusable, and on mainline 7.2 actively harmful.** No Valve kernel binds it: 6.18.42's `mt7921e` advertises `7920`/`7922`/`7961` and no `7902`, so the device sits unpowered with its BARs `[disabled]`. Mainline 7.2 *does* bind it (`c26319afb5fb`), which is worse - MediaTek have never published MT7902 Wi-Fi firmware, so probe fails, the device stays bound anyway, and `mt7921_pci_remove()` (which is also `.shutdown`) then hangs every power-off in `napi_disable_locked`. `mt7921e` is blacklisted here; see [hardware/kernel/](hardware/kernel/README.md).
- **Bluetooth - `btusb` binds, then bails.** All three interfaces of `1-10` are bound to `btusb` and `hci1` is created, but setup aborts with:

  ```
  Bluetooth: hci1: Unsupported hardware variant (00007902)
  ```

  That is `btmtk` hitting its default case on the chip ID. `hci1` is left permanently `DOWN` with BD address `00:00:00:00:00:00`. Strings in `btmtk.ko` show the only variants it knows are MT7922 / MT7961 / MT7925, and `/usr/lib/firmware/mediatek/` matches exactly that - there is no `BT_RAM_CODE_MT7902_*` blob, and supplying one would not help because the variant check rejects the device before firmware load is ever attempted.
- Because BT is a USB endpoint rather than part of the PCIe function, the two fail independently. Symlinking MT7922/MT7925 BT firmware does not work - it fails with "Failed to get patch semaphore".

#### Resolution (Bluetooth)

Fixed with an out-of-tree `btusb_mt7902` module built from
[hmtheboy154/mt7902](https://github.com/hmtheboy154/mt7902) `bluetooth_backport`
(MediaTek's 7.1 patches backported), plus the `BT_RAM_CODE_MT7902_1_1_hdr.bin`
firmware that branch ships. Onboard Bluetooth is now `hci0`
(MediaTek, HCI 5.2, real BD_ADDR) and is BlueZ's default controller;
scanning works.

Three local changes were needed on top of upstream. The important one: upstream's
`quirks_table` has **no entry for `0e8d:7902`** and, unlike mainline, no
vendor-wide `0x0e8d` match - so our device never got `BTUSB_MEDIATEK`,
`btusb_mtk_setup()` never ran, and the backport's new `case 0x7902:` was dead
code. The other two (un-exporting `btmtk`'s symbols, renaming the `usb_driver`)
are needed so the module can coexist with the in-tree `btusb`/`btmtk`, which
stay loaded. Full write-up in [hardware/bluetooth/](hardware/bluetooth/README.md).

The dongle (Realtek `0bda:a725`, `hci2`) still works and is worth leaving in as
a fallback: DKMS-style modules land in `/usr/lib/modules/$KVER/updates/` and are
wiped by every SteamOS A/B update. `mt7902-bt.service` restores them at boot
from a cache under `/home` - offline and sub-second unless the kernel version
changed, which forces a rebuild.

Delete all of this when SteamOS rebases onto a 7.1+ kernel and use the in-tree
driver instead.
