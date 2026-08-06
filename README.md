# DIY Steam Machine Scripts & Helpers

- [WIP](#wip)
- [TODO](#todo)
- [Working (done)](#working-done)
  - [Not working (yet)](#not-working-yet)
- [Hardware](#hardware)
- [Platform notes](#platform-notes)
  - [SteamOS persistence](#steamos-persistence)
  - [SMBus and I2C on AM5](#smbus-and-i2c-on-am5)
  - [Display: 4K120 over HDMI (amdgpu)](#display-4k120-over-hdmi-amdgpu)
  - [Onboard wireless (MediaTek MT7902)](#onboard-wireless-mediatek-mt7902)

## WIP

- HDMI 2.1 FRL (4K120), see [hardware/kernel/README.md](hardware/kernel/README.md)

## TODO

Things I haven't got around to investigating or doing yet
Priorities below are (H)igh, (M)edium, (L)ow.

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
- **4K 120Hz over the native HDMI port** - working (2026-08-06) on a hand-built mainline **Linux 7.2-rc6** with HDMI 2.1 FRL enabled (`amdgpu.dcfeaturemask=0x402`). **3840×2160 @ 120 Hz, RGB 4:4:4, 12 bpc, uncompressed, HDR10, `underflow 0`, single pipe** - measured at a 1188.00 MHz pixel clock, 1.98× the 600 MHz HDMI 2.0 TMDS ceiling. Strictly better than the converter it replaces (10 bpc *with* DSC, plus glitching), and the adapter is out of the chain. Verified rather than assumed that no Valve kernel can do this: `amdgpu.ko` extracted from 6.16.12, 6.18.33 and 6.18.38 all have a byte-identical FRL symbol set, and none contain the native `dcn401_hpo_frl_stream_encoder`. See [hardware/kernel/](hardware/kernel/README.md), with the raw capture in [`frl-4k120-evidence.txt`](hardware/kernel/frl-4k120-evidence.txt). It is now the **default boot entry** and **survives SteamOS updates**: a keep-listed systemd unit restores it from a cached tarball on `/home` after an image swap, at a cost of one boot on the stock kernel. `grub.cfg` stays byte-for-byte stock, so a failure anywhere in this falls through to Valve's kernel. **VRR works too** (2026-08-06): 40-120 Hz, `vrr_capable 1`, via AMD's unmerged 4-patch series hand-ported onto the build - see [hardware/kernel/patches/](hardware/kernel/patches/). CEC still does not work and is not fixable in software: amdgpu registers no CEC adapter for its own HDMI ports on any kernel.
- **4K 120Hz via a DP converter** - *superseded by the above, kept because it still works and is the fallback.* Working 2026-08-02 via a **UGREEN 80397** active DP 1.4 → HDMI 2.1 converter on `DP-1`, immediately on hotplug with no configuration. 4:4:4 10-bit with HDR, DSC active, `underflow 0`. See [hardware/display/](hardware/display/README.md). VRR does not work through this converter and is not being chased - see below.
- **"No signal" when the TV is switched on after the machine** - the converter is the DP sink, not the TV: it holds HPD asserted and answers EDID from cache whether the TV is on or off, so a modeset landing while the TV is off strands it forever, with every driver-side reading claiming a healthy 4K120 link. Nothing on this side can detect the TV's power state - DPCD, DDC, DDC/CI and the audio ELD were all sampled across a power cycle and are bit-identical, so a polling daemon has nothing to poll. Fixed by forcing a replug through debugfs `trigger_hotplug`, wired to four triggers: **Shift+Esc**, controller connect, boot and resume. See [hardware/display/](hardware/display/README.md).
- **GPU overdrive (LACT) made persistent** - LACT's "enable overclocking" writes `/etc/modprobe.d/99-amdgpu-overdrive.conf`, which is *not* on the SteamOS keep list, so every A/B update silently deletes it and every LACT control goes back to greyed-out. Confirmed by recovering the file from the `/etc` snapshot the 1 Aug update took just before discarding it. Now allowlisted, with a boot self-heal. See [hardware/gpu/](hardware/gpu/README.md). Confirmed active after the reboot: `--status` reports the overdrive bit set.
- **Sleep during remote sessions** - the machine kept suspending out from under SSH sessions. It is not systemd idle (`logind.conf` sets no `IdleAction`): Steam's Deck-UI sleep timer asks logind to suspend, and an SSH session is not activity as far as gamescope is concerned. Because the request goes *through* logind it can be refused, so a root daemon now holds a `block` inhibitor on `sleep` while any sshd session exists, plus a 30-minute grace window after the last one ends (cut from two hours on 2026-08-03, after the journal showed only two suspends in three days - a machine that never sleeps wastes more than any idle tunable saves). A polkit rule additionally lets `deck` take the same lock by hand (`keepawake 4h`) - without it a remote `systemd-inhibit` hangs on an unanswerable password prompt, because an SSH session is neither "active" nor "inactive" to polkit and falls through to `auth_admin_keep`. See [hardware/sleep/](hardware/sleep/README.md).
- **sshd policy pinned, and keepalives enabled** - `/etc/ssh/sshd_config.d/10-steam-machine.conf` was tracked nowhere and pinned by nothing; the keep list covers `/etc/ssh/*_key` and nothing else, so `AllowUsers deck` and `PermitRootLogin no` would have silently reverted to stock Arch defaults on the next A/B update - a quiet loosening of access policy with no symptom at all. Now in the repo, allowlisted, with a boot self-heal that validates via `sshd -t` and rolls back rather than risking a lockout. Also sets `ClientAliveInterval 60` / `ClientAliveCountMax 5`: with keepalives off (the default) a dropped client leaves its session registered with logind for up to ~2 h 11 m of TCP timeout, which would pin the machine awake through the inhibitor above. The two are a pair. See [system/ssh/](system/ssh/README.md).
- **Idle power** - `powertop` was run because the CPU appeared pinned at 4 GHz+ at idle. It is not: `scaling_cur_freq` and `/proc/cpuinfo` both derive from APERF/MPERF, which on AMD only tick in C0, so they report the clock during the awake slices and are blind to halted time. Measured residency is 93% idle (77% in C3), and `amd-pstate-epp` is already doing the right thing by racing to clock and dropping back into CC6. Of powertop's ~45 suggestions three survived triage: `kernel.nmi_watchdog=0`, `vm.dirty_writeback_centisecs=1500`, and SATA `med_power_with_dipm` on the two MX500s. Its 41 "Bad" runtime-PM entries reduce to about four decisions - ~20 are PCI devices with no driver bound, so `auto` has nothing to invoke; five are the single fact that one xHCI controller cannot suspend while the controllers and headset plugged into it are pinned on; one is a powertop bug (it string-compares `snd_hda` `power_save` against "1" when the value is "10" and all three codecs are already suspended). Every rejection is recorded with its evidence so the next powertop run doesn't re-derive them. See [system/power/](system/power/README.md).
- **Shell setup in the repo** - the aliases and `PATH`/env exports that were only ever in `~/.bashrc`: `g`/`p`/`P`/`gitwip`, the `cc`/`ccd`/`cccd`/`ccrd` Claude Code aliases, `vi`, and the Homebrew / `~/.local/bin` / `.NET SDK` `PATH` setup. Sourced from the repo rather than copied, so the version under git is the one actually in use. `trigger_detect_tv` was the one machine-specific alias and was stale - it wrote to a hardcoded `dri/0/DP-1` path; it now calls `display-redetect`, the same script the four automatic triggers run. The subsystem-specific shell functions (`keepawake`, `wayland`, `coolercontrol`) stay with their own hardware. See [system/shell/](system/shell/README.md).

### Not working (yet)

#### VRR through the DP converter (L)

4K120 is done; VRR is not, and **is not worth chasing on this adapter**. Tested and reverted 2026-08-02.

`amdgpu` whitelists DP-to-HDMI converters by branch device ID. `freesync_pcon_allow_all=1` bypasses that, and the bypass worked - the UGREEN identified as `branch_dev_id : 2818800` (`0x2B02F0`). But VRR stayed `incapable` / `vrr_range 0-0` anyway: the converter doesn't pass FreeSync through to the TV, so the whitelist was never the constraint.

A vertical seam also appeared at 4K120 in that session. Neither the parameter nor ODM combine causes it: ODM 2:1 is active regardless (it's the only way 1188 MHz runs on the converter path) and the seam went away with ODM still on. Cause unresolved, not recurring; the session's X11-vs-Wayland state was never recorded, which is the likely confound. Detail in [hardware/display/](hardware/display/README.md).

Dropped to (L): it would need a different converter, or upstream FRL on a 7.2+ kernel.

**Update 2026-08-06: the converter is no longer in the chain**, so this entry is now history - 4K120 runs over the native HDMI port on a 7.2-rc6 build with FRL, and **VRR works**. Stock 7.2 shipped FRL *without* HDMI VRR, deliberately; Fangzhi Zuo at AMD posted a 4-patch series on 30 July 2026 adding it over the FRL path, Reviewed-by Harry Wentland. Unmerged, but hand-ported onto the 7.2-rc6 build and now running: `vrr_range Min: 40 Max: 120`, `vrr_capable 1`. The patches are in [hardware/kernel/patches/](hardware/kernel/patches/). See [hardware/kernel/](hardware/kernel/README.md).

#### HDMI CEC (M)

Does not work **on the native HDMI port**, and moving to it did not fix it. Verified 2026-08-07 from `amdgpu.ko`'s own symbol table rather than inferred: every CEC symbol the module imports is either `cec_notifier_*` (publishes the EDID physical address *for* a separate CEC adapter driver; allocates nothing) or `drm_dp_cec_*` (CEC-Tunnelling-over-AUX, which needs a DP→HDMI branch device that implements CEC itself). The adapter-registration API - `cec_allocate_adapter`, `cec_register_adapter`, `drmm_connector_hdmi_cec_adapter_register` - is absent entirely, so there is no `/dev/cec*` and nothing to attach one to. The `hdmi_cec_state` debugfs entry reporting `HDMI-CEC status: 1` is the *sink's* advertised capability read over DDC, not a Linux adapter.

**The silicon has no CEC controller either**, so this is not a driver holding back hardware. AMD's own register headers in the 7.2-rc6 tree contain **zero** `CEC` macros across every DCN generation (1.0 → 4.1.0); the DCE-era headers have exactly one, a read-only `DC_PINSTRAPS_BIF_CEC_DIS` pinstrap bit that no code in the kernel reads and which is not a controller (no TX/RX buffer, no logical-address, status or interrupt register). There is no CEC command in the DMUB firmware enum either. Whether HDMI pin 13 is physically wired on this board is unresolved and moot - there is nothing in the ASIC to drive it.

**Reports of "CEC works on my 9070 XT" are the DisplayPort tunnel, not the HDMI port.** [Twsts/steamos-cec-toolkit](https://github.com/Twsts/steamos-cec-toolkit) - a SteamOS CEC toolkit worth knowing about - is built and tested on exactly that card with **a UGREEN DP→HDMI CEC adapter** providing `/dev/cec0`. It is installed here and inert until an adapter exists.

That suggests an untested route worth the five minutes: put a CEC-tunnelling DP→HDMI adapter on a **spare DisplayPort output and an unused TV input**, leaving 4K120 FRL on the native HDMI port. CEC is a bus, so control should work whichever input the TV is showing. Otherwise a USB CEC adapter (Pulse-Eight, ~$60 AUD) is the option that definitely works. See [hardware/kernel/](hardware/kernel/README.md).

##### Onboard WiFi (L)
- Bluetooth is **now working** - see [hardware/bluetooth/](hardware/bluetooth/README.md) and the [platform note below](#onboard-wireless-mediatek-mt7902).
- WiFi is still unsupported on kernel 6.16 and not worth chasing while 2.5G wired works. The same upstream repo has a `backport` branch that builds `mt7902e.ko` for the PCIe side if it ever matters.

#### Controller wake from sleep (H)
- Wake from bluetooth controller not working (Playstation 5 DualSense)
- There is an upstream report that the 2026 Steam Controller and its puck also fail to wake from suspend ([bazzite#4873](https://github.com/ublue-os/bazzite/issues/4873)) - **not tested here**, noted only because it touches the same item.

#### Disabling RGB Lighting (M)
RBG is pretty tacky and certainly distracting in a living room environment.

##### Kingston RGB RAM
- **Now detected.** Support was never the problem: it merged in [MR !2435](https://gitlab.com/CalcProgrammer1/OpenRGB/-/merge_requests/2435) on 2024-07-23. The cause was local.
- **Root cause found (2026-08-02):** it was never a wrong-port problem - there were **no `i2c-piix4` ports at all**. The firmware declares an ACPI OperationRegion over the SMBus I/O range, and `acpi_enforce_resources=strict` (the kernel default) made `i2c-piix4` register zero adapters. Fixed with `acpi_enforce_resources=lax` while setting up sensors; see [hardware/sensors/](hardware/sensors/README.md#the-fch-smbus-is-blocked-by-acpi). Confirmed after the reboot: OpenRGB detects the RAM on `i2c-2` and it is blanked via Static mode. See [hardware/rgb/](hardware/rgb/README.md).
- Also worried about bricking the RAM with OpenRGB as per [this post](https://github.com/ubihazard/ddr5-spd-recovery). An SPD baseline is now committed at `hardware/sensors/baseline/`, with `hardware/sensors/bin/spd-check.sh` to diff against it.
- A bespoke SMBus writer was designed and abandoned - see `git log -- hardware/ram/`. It was premised on a wrong-i2c-port theory and on never installing OpenRGB; the real blocker was the ACPI SMBus conflict, and OpenRGB is what actually blanks the DIMMs. Handled by [hardware/rgb/](hardware/rgb/README.md).

##### XFX Radeon RX 9070 XT OC Gaming Edition
- **The card has no RGB controller - OpenRGB can never detect it as a GPU.** All six I²C buses belonging to `0000:03:00.0` (`AMDGPU SMU 0/1`, `AMDGPU DM i2c hw bus 0-3`) are empty, and nothing on USB/hidraw belongs to the card. Cards OpenRGB does support (Sapphire Nitro+, ASUS TUF, Gigabyte AORUS, PowerColor Red Devil - all already compiled into the installed 1.0rc3) have a real microcontroller on one of those buses; this one does not. Upstream request [#5154](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/5154) is for this exact card (subsystem `1EAE:8811`) and its "device captures" section is blank, because there is nothing to capture.
- The shroud strip is a **dumb 5V ARGB slave with an input connector**, not an addressable device. XFX's own wording: *"a full-length 5-volt ARGB element across the shroud"* plus a supplied **sync cable**. Unconnected it runs a hardcoded rainbow from a small onboard driver, which is what makes it look software-reachable.
- **The fix is to plug the XFX sync cable into one of the board's three ARGB_V2 headers**, at which point the strip becomes a zone of the `B850M FORCE WIFI6E V2` (ITE IT5711) controller OpenRGB already detects. Handled by [hardware/rgb/](hardware/rgb/README.md), which sizes and blanks all three headers so it doesn't matter which one is used. **Pending: cable not yet connected.**
- Set via OpenRGB's **Static** mode, not Direct - Static is committed to the IT5711 and survives OpenRGB exiting and a power cycle, so the systemd units are a safety net rather than the mechanism.

##### OpenRGB access rules
- The `/usr/lib/udev/rules.d/60-openrgb.rules` on this machine is **owned by no package** (`pacman -Qo` confirms) and was dropped in by hand. `/usr` is replaced wholesale by every A/B update, so it will vanish. It also grants uaccess to *every* i2c bus - including the FCH SMBus with the always-host-writable DDR5 SPD EEPROMs, the exact hazard the section above is paranoid about. Replaced by a narrow two-stanza rule in `/etc` by [hardware/rgb/](hardware/rgb/README.md).
- While that file is present it **overrides** the narrowing: `install.sh --no-i2c` strips the SMBus stanza from our rule but the blanket `KERNEL=="i2c-[0-99]*"` re-grants the bus anyway (verified - the ACL survived and OpenRGB still saw the RAM). `install.sh --status` reports this, and `--drop-upstream-rules` removes the file after backing it up.
- There is **no `hid` group** on this system - `/dev/hidraw*` access comes from a `uaccess` POSIX ACL, not group membership. An `i2c` group exists but adding `deck` to it would be worse: group membership is unconditional and machine-wide, while `uaccess` is scoped to the owner of the active seat and revoked on logout.

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

The following are **inferred** from Claude searching online - **before** setting Claude up on the hardware itself, when I do that I'll get Claude to validate, correct and enhance these notes.

### SteamOS persistence

SteamOS 3.x boots a read-only btrfs root from an A/B pair. An update writes a whole new image to the inactive slot and boots into it, so anything in `/usr`, `/opt` or `/usr/local` is gone after the next update. That includes anything `pacman -S` installed after `steamos-readonly disable`.

**Btrfs confirmed** (`findmnt -no SOURCE,FSTYPE /` → `/dev/nvme0n1p5 btrfs`). Note that on this box `steamos-readonly status` currently reports **disabled**, so the root is mounted `rw` - that is a local change, not the stock state, and it does not make anything survive an update.

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

**Superseded 2026-08-06 - 4K120 now runs over the native HDMI port**, on a hand-built mainline 7.2-rc6 with FRL enabled. See [hardware/kernel/](hardware/kernel/README.md). Everything below remains accurate as the diagnosis of *why* a SteamOS kernel cannot do it, and describes the DP-converter fallback, which still works.

**Validated on-machine 2026-08-02** - 4K120 over an active DP → HDMI 2.1 converter. Full write-up in [hardware/display/](hardware/display/README.md). Measured on that link: 4 lanes @ HBR3 (8.1 Gbps/lane, 32.4 Gbps), DSC active at 16 bpp from 30 bpp, RGB 4:4:4 10-bit, HDR on, `underflow 0`.

That was described at the time as "better than native FRL would have given". **That has now been tested and it is not true**: native FRL delivers 4:4:4 at **12 bpc, uncompressed, on a single pipe** - better on every axis than the converter's 10-bit-with-DSC. The prediction was made against the 4:2:0 workaround below, not against real FRL.

> **The TV is this machine's only console.** An unsyncable mode = black screen with no way to type the fix, which happened during this work. Arm a revert timer before any experimental modeset - `(sleep 20; kscreen-doctor output.<out>.mode.<safe-idx>) &` - and when unwinding, set a safe mode *first* and remove `force_yuv420_output` *second*. The signal must stay legal at every intermediate step.

The 4K60 ceiling is not the cable or the TV - the C9's EDID advertises `VIC 118: 3840x2160 120 Hz` and FRL up to 12 Gbps/lane. The HDMI Forum rejected AMD's open-source HDMI 2.1 implementation in 2023-24, leaving `amdgpu` capped at HDMI 2.0's **600 MHz TMDS character rate**. 4K120 at 4:4:4 needs 1188 MHz.

Confirmed on this kernel by extracting the module rather than trusting release notes - `DC_FRL_MASK` is absent, and every `FRL` string present belongs to the DP-to-HDMI PCON (adapter) path:

```bash
zstd -d /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst -o amdgpu.ko
strings amdgpu.ko | grep -i frl
```

Status as of August 2026:

- FRL **merged for Linux 7.2**, in rc now, stable expected late August 2026. It is **off by default** because VRR-over-FRL did not land with it. DSC-over-FRL *did* merge.
- The enabling parameter is widely misquoted online as `amdgpu.dc_feature_mask=0x400`. **Both parts are wrong**: it is spelled `dcfeaturemask`, and it *replaces* the mask rather than OR-ing into it - on this machine the live value is `2`, so it would need `0x402`.
- Valve has backported the ALLM/HDMI-VRR half (`allm_mode`, `hdmi_vrr_desktop_mode` both exist here) but **not** FRL. SteamOS 3.8 is on 6.16.
- The out-of-tree work preceding the merge was tested on DCN 4.0.1 - Navi 48, this exact GPU. RDNA4 is the best-tested path.

Until SteamOS rebases onto 7.2+:

- The **active DP-to-HDMI 2.1 converter is the correct fix**, now confirmed in practice. The GPU emits plain DisplayPort, which has no HDMI Forum entanglement. DSC is required, not marketing: 4K120 RGB 10-bit needs ~35.6 Gbps uncompressed against HBR3's ~25.9 Gbps effective; the link negotiated 16 bpp DSC, which is ~19 Gbps. A **passive** DP++ adapter would land back at 4K60.
- `amdgpu.freesync_pcon_allow_all=1` looks like the fix for VRR through a converter, and **does nothing useful on this hardware** - the adapter doesn't pass FreeSync through regardless, so VRR stays `incapable`. Pinned explicitly to `0`.
- **Desktop mode is X11 or Wayland depending on how you enter it**, and X11 has no colour management - wide-gamut content goes to the OLED unmanaged and looks badly over-saturated, with HDR/WCG/ICC controls missing from KDE entirely. Steam's Power → Switch to Desktop hardcodes X11; booting into desktop mode gives Wayland. `steamos-session-select plasma-wayland` fixes it for the current session.
- **4:2:0 does _not_ work out of the box.** The C9's YCbCr 4:2:0 Capability Map lists only 4K60/50, so the driver prunes 4K120 outright. It takes a one-byte EDID patch (ext block byte 93, `0x33`→`0x3f`) *plus* `force_yuv420_output=1`. That combination was measured working and stable, but is 4:2:0 8-bit only - no headroom for 10-bit at 594 MHz - so text is soft and HDR bands. Rejected.

### Onboard wireless (MediaTek MT7902)

This board uses a **MediaTek MT7902** (Filogic 310, Wi-Fi 6E + BT 5.3), not the MT7922/MT7925 that most Gigabyte AM5 boards ship. Both functions are now **confirmed on-machine**:

- WiFi is the PCIe function: `lspci -nn | grep -i net` → `08:00.0 Network controller [14c3:7902]`.
- Bluetooth is a **separate USB device** on MediaTek's own vendor ID: `lsusb` → `Bus 001 Device 005: ID 0e8d:7902 MediaTek Inc. Wireless_Device`.
  (An earlier revision of these notes listed the BT device as `13d3:3579` - that was from secondary sources and is wrong for this board.)

Why neither worked out of the box (**Bluetooth is now fixed** - see
[hardware/bluetooth/](hardware/bluetooth/README.md); WiFi is still unsupported):

- Mainline MT7902 support only landed in **kernel 7.1** (MediaTek's patch series posted to linux-wireless 2026-02-19). **SteamOS 3.8 ships kernel 6.16** (`6.16.12-...-neptune-616`), so there is no in-tree driver for either function today.
- **WiFi - nothing binds at all.** No module in 6.16 advertises the PCI ID; `modprobe -c | grep 14C3` lists `0608`/`0616` → `mt7921e` and `0717` → `mt7925e`, but no `7902`. `/sys/bus/pci/devices/0000:08:00.0/driver` does not exist and `lspci -vv` shows the BARs still `[disabled]` - the device has never been powered up.
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
