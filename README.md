# DIY Steam Machine Scripts & Helpers

Scripts, configs and notes for a DIY Steam Machine — an AM5 box running SteamOS as a console on the lounge TV.

Two constraints shape everything here:

- **Every change must survive a reboot _and_ a SteamOS A/B update.** SteamOS replaces `/usr` wholesale on update and keeps only an allowlisted subset of `/etc` — see [docs/steamos-platform-notes.md](docs/steamos-platform-notes.md).
- **The TV is this machine's only console.** A modeset that won't sync means no way to type the fix — see [the warning in hardware/display/](hardware/display/README.md#warning-the-tv-is-this-machines-only-console).

Contents:

- [Solved](#solved)
- [Outstanding](#outstanding)
- [TODO](#todo)
- [After a SteamOS update](#after-a-steamos-update)
- [Repo map](#repo-map)
- [Hardware](#hardware)

## Solved

One line each. The linked write-up carries the evidence, the install script, and what it takes to survive an update.

| What | Result | Detail |
| --- | --- | --- |
| 4K120 on the **native HDMI port** | 3840×2160@120, RGB 4:4:4, 12 bpc, uncompressed, HDR10, plus VRR 40–120 Hz. Hand-built mainline 7.2-rc6 with HDMI 2.1 FRL (`amdgpu.dcfeaturemask=0x402`), now the default boot entry and restored automatically after an OS update. | [hardware/kernel/](hardware/kernel/README.md) |
| 4K120 via a **DP→HDMI converter** | Superseded by the above, kept as the fallback. 4:4:4 10-bit HDR with DSC, no custom kernel. Three-way measured comparison of every 4K120 path in [4k120-paths.md](hardware/display/4k120-paths.md). | [hardware/display/](hardware/display/README.md) |
| "No signal" when the TV is switched on after the machine | The converter, not the TV, is the DP sink and answers EDID from cache, so nothing on this side can detect the TV's power state. Fixed by forcing a replug via debugfs, wired to Shift+Esc, controller connect, boot and resume. | [hardware/display/](hardware/display/README.md) |
| Power-off hangs | Two independent causes, both fixed: `mt7921e` binding the unusable onboard Wi-Fi, and the Gamescope session holding the GPU (VT switch at shutdown). | [hardware/kernel/](hardware/kernel/README.md#solved-power-off-hangs-2026-08-06-to-2026-08-08) |
| 2026 Steam Controller on a mainline kernel | Valve's `hid-steam` backported out of SteamOS 6.18.42 onto 7.2-rc6 as patches 0007-0008 — compiles unmodified. All nine puck interfaces bind `hid-steam` and `/dev/input/js*` appears. Not upstream anywhere: nothing referencing IBEX/PROTEUS/NEREID exists in public kernel git. | [hardware/controller/](hardware/controller/README.md) |
| Onboard Bluetooth (MediaTek MT7902) | Out-of-tree `btusb_mt7902` — `hci0` with a real BD_ADDR, BlueZ default controller, survives reboots and A/B updates. The USB dongle is no longer needed but stays as a fallback. | [hardware/bluetooth/](hardware/bluetooth/README.md) |
| Hardware sensors | Fan RPM / Vcore / VRM temp from the ITE IT8696E (out-of-tree `it87`), SATA SSD temps (`drivetemp`), and DDR5 DIMM temps once the FCH SMBus was unblocked. Labels verified by correlation under load, not guessed. | [hardware/sensors/](hardware/sensors/README.md) |
| CoolerControl | Temp/fan/power monitoring on port **11987**, LAN-reachable. Never touches fan curves (`apply_on_boot = false`). **Off by default** — a LAN-exposed root daemon, so turn it on per session with `coolercontrol on` / `off`. | [hardware/coolercontrol/](hardware/coolercontrol/README.md) |
| Secondary game library (BTRFS RAID1) | Two Crucial MX500s mirrored at `/home/deck/SATA` via fstab, `compress=zstd:1`, `discard=async`, `noatime`, monthly scrub, weekly trim — around SteamOS's automount, which refuses anything that isn't ext4. One manual step left, see [Outstanding](#outstanding). | [hardware/storage/](hardware/storage/README.md) |
| GPU overdrive (LACT) made persistent | LACT writes `/etc/modprobe.d/99-amdgpu-overdrive.conf`, which is not on the keep list, so every update silently reverted the controls to greyed-out. Now allowlisted with a boot self-heal. | [hardware/gpu/](hardware/gpu/README.md) |
| RGB lighting off | Motherboard, RAM and GPU dark. The Kingston RAM was never a wrong-port problem — there were no `i2c-piix4` ports at all until `acpi_enforce_resources=lax`. Set via OpenRGB **Static** mode, which is committed to the controller, with systemd units as the safety net. | [hardware/rgb/](hardware/rgb/README.md) |
| Sleep during remote sessions | Steam's Deck-UI sleep timer suspended the machine out from under SSH. A root daemon now holds a `block` inhibitor while any sshd session exists, plus a 30-minute grace window; a polkit rule lets `deck` take the same lock by hand (`keepawake 4h`). | [hardware/sleep/](hardware/sleep/README.md) |
| Wake-on-LAN | Armed by both a `.link` drop-in (every boot, before NetworkManager exists) and an NM property (survives A/B updates for free). In-tree `r8169` is enough; no DKMS. | [hardware/network/](hardware/network/README.md) |
| sshd policy pinned, keepalives enabled | `AllowUsers deck` / `PermitRootLogin no` were pinned by nothing and would have reverted to stock Arch defaults on the next update — a silent loosening of access policy. Now allowlisted with a self-heal that validates via `sshd -t` and rolls back. | [system/ssh/](system/ssh/README.md) |
| Inbound IPv6 firewall | SteamOS opens `1024-65535/tcp,udp` on the public zone with no address family restriction, and this box holds a globally routable address. IPv6 from outside the LAN is now dropped; IPv4 untouched. | [system/firewall/](system/firewall/README.md) |
| Idle power | The CPU was never pinned at 4 GHz — `scaling_cur_freq` is blind to halted time on AMD. Measured 93% idle. Three powertop suggestions of ~45 survived triage; every rejection recorded with its evidence so the next run doesn't re-derive them. | [system/power/](system/power/README.md) |
| RustDesk remote desktop | Unattended graphical access to Desktop Mode, LAN-only, installed onto an immutable rootfs and restored after updates. | [system/rustdesk/](system/rustdesk/README.md) |
| btop GPU box | btop's only AMD backend is the ROCm SMI library, which SteamOS doesn't ship — so the setting existed but silently reset itself. Library installed, box enabled. | [system/btop/](system/btop/README.md) |
| htop layout | Kept for both `deck` and `root` across reboots and updates. | [system/htop/](system/htop/README.md) |
| PortProton default wine version | Tracks the newest installed GE-Proton automatically via a user path unit, instead of a file PortProton rewrites on every update. | [system/portproton/](system/portproton/README.md) |
| Shell setup in the repo | Aliases and `PATH`/env exports sourced from the repo rather than copied, so the version under git is the one in use. | [system/shell/](system/shell/README.md) |
| Filesystem basics | TRIM (`discard`) and `noatime` set in fstab. | — |

A bespoke SMBus writer for the RAM was designed and abandoned (`git log -- hardware/ram/`): it was premised on a wrong-i2c-port theory, the real blocker was the ACPI SMBus conflict, and OpenRGB is what actually blanks the DIMMs.

## Outstanding

Priorities are (H)igh, (M)edium, (L)ow.

| What | Pri | State | Detail |
| --- | --- | --- | --- |
| Controller wake from sleep | H | The DualSense over Bluetooth does not wake the machine. An upstream report says the 2026 Steam Controller and its puck don't either ([bazzite#4873](https://github.com/ublue-os/bazzite/issues/4873)) — not tested here. | [hardware/controller/](hardware/controller/README.md#related) |
| HDMI CEC | M | **Impossible on the native HDMI port** — amdgpu registers no CEC adapter and the silicon has no CEC controller (zero `CEC` macros across every DCN generation). **Confirmed working over a DP→HDMI converter** (2026-08-10): `/dev/cec0`, CEC 2.0, and SteamOS's `cecd` picks it up unaided. Untested in the configuration that would keep both — converter on a spare DP output as a CEC-only endpoint, video staying on native HDMI. A USB CEC adapter (Pulse-Eight, ~$60 AUD) also works. | [4k120-paths.md](hardware/display/4k120-paths.md#cec-only-exists-on-the-converter-path), [hardware/kernel/](hardware/kernel/README.md#cec-still-does-not-work-m) |
| Register the SATA array as a Steam library | M | The array is mounted and surviving remount; adding it as a library is a manual step and has to be done with Steam closed. | [hardware/storage/](hardware/storage/README.md) |
| Rebase the FRL kernel onto Valve's tree | M | Currently mainline 7.2-rc6, so Valve's own patches (controller IDs aside) are absent. Alternative is waiting for 7.2 final and then for SteamOS to rebase. | [hardware/kernel/](hardware/kernel/README.md#next-steps) |
| Upstream OpenRGB udev rule overrides ours | L | `/usr/lib/udev/rules.d/60-openrgb.rules` is owned by no package, grants uaccess to *every* i2c bus, and re-grants the SMBus even when `install.sh --no-i2c` narrows our rule. It vanishes on each update anyway; `install.sh --drop-upstream-rules` removes it deliberately. | [hardware/rgb/](hardware/rgb/README.md#access-control-and-why-the-shipped-rules-are-not-used) |
| GPU shroud ARGB strip | L | A dumb 5V ARGB slave, not an addressable device — it needs the XFX sync cable plugged into one of the board's ARGB_V2 headers, at which point it becomes a zone of the controller already being blanked. Cable not yet connected. | [hardware/rgb/](hardware/rgb/README.md) |
| VRR through a DP converter | L | Both silicon preconditions are met and measured; the only unmet condition is amdgpu's hardcoded five-OUI whitelist, which the CH7218 is absent from. Not being chased — native HDMI VRR works. | [4k120-paths.md](hardware/display/4k120-paths.md#vrr-the-adapter-is-capable-amdgpu-refuses) |
| Onboard WiFi (MediaTek MT7902) | L | Unsupported and deliberately blacklisted: mainline 7.2 binds the device but MediaTek have never published its Wi-Fi firmware, and the driver's remove path then hangs power-off. Not worth chasing while 2.5G wired works. | [hardware/kernel/](hardware/kernel/README.md#1-mt7921e-binding-the-onboard-mt7902-wi-fi) |
| Blank screen on the boot after a forced power-off | L | Correlates with the 4-second power-button hold, clears on a second power cycle. Cause unidentified. | [hardware/kernel/](hardware/kernel/README.md) |

## TODO

Things I haven't got around to investigating or doing yet.

- Configuration backup (M)
- DualSense adaptive triggers — not sure if they work / how to configure them (M)
  - https://github.com/egormanga/SAxense
  - https://hardwaretester.com/gamepad
  - https://github.com/awalol/DS5Dongle (this looks cool!) — https://ds5-dev.awalol.eu.org/
- Emulation setup: retrodeck, restore ROMs and metadata from the Steam Deck (L)
- Overclocking the GPU (L) — the _controls_ are available and persistent ([hardware/gpu/](hardware/gpu/README.md)); no clocks, limits or fan curves have actually been set
- Cloud saves for non-Steam games (L)
- Investigate extracting saves from a few PS5 games (Blue Prince, for example) and copying them to SteamOS (L)

## After a SteamOS update

Every subsystem installs a systemd unit that runs its own `install.sh --boot` at each boot, so an A/B update repairs itself with no intervention. The top-level script does the same thing *now*, in one place, with the output in front of you:

```bash
sudo ./install.sh            # restore everything a SteamOS update removed
sudo ./install.sh --status   # report every subsystem, change nothing
./install.sh --list          # which subsystems support which modes
```

It runs `hardware/kernel` first, because that restores `/usr/lib/modules` and the out-of-tree modules (`it87`, `btusb_mt7902`) need a module tree that already exists. A failing subsystem does not stop the others, and the script exits non-zero if any failed.

The first boot after an update lands on the **stock Valve kernel** — the update replaces the EFI partition wholesale, taking `custom.cfg` with it. That is deliberate. Run the command above, reboot, and you are back on the FRL kernel.

## Repo map

| Path | What |
| --- | --- |
| `install.sh` | Runs every subsystem's installer in one pass — `--boot`, `--status`, `--list` |
| `lib/` | Shared shell helpers (`elevate.sh` — re-runs a script under sudo, choosing the prompt method by whether there's a TTY) |
| `hardware/*/` | One directory per device or capability: kernel, display, controller, bluetooth, network, sensors, coolercontrol, storage, gpu, rgb, sleep |
| `system/*/` | OS-level config: ssh, firewall, power, rustdesk, shell, htop, btop, portproton |
| `docs/steamos-platform-notes.md` | SteamOS A/B persistence rules and AM5 SMBus/I2C facts — the platform assumptions everything else relies on |
| `CHANGELOG.md` | Dated log of every change, newest first |

Each subsystem directory has its own `README.md` and, where there's anything to install, an idempotent `install.sh` supporting `--status` and usually `--boot`.

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
| Crucial 2TB SATA SSDs x2 (already had)     |            |                $0.00 |

Links:

- https://www.scorptec.com.au/product/graphics-cards/amd/116057-rx-97trgbbb9
- https://www.scorptec.com.au/product/cases/micro-atx/112747-pc-a3x-wd
- https://www.scorptec.com.au/product/memory/ddr5-desktop-memory/113814-kf560c36bbe2ak2-32
- https://www.scorptec.com.au/product/motherboards/amd-socket-am5/123608-b850m-force-wf6e-v2
- https://www.scorptec.com.au/product/cooling/cpu-coolers/114722-cw-9060089-ww
- https://www.scorptec.com.au/product/power-supplies/rackmount-slim/110637-cp-9020256-au
- https://www.scorptec.com.au/product/hard-drives-and-ssds/solid-state-drives--ssd/126628-bnv740002tb-rgx
- https://www.scorptec.com.au/product/cpu/amd-socket-am5/114321-100-100001084wof
