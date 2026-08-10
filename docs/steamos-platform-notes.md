# Platform notes — SteamOS persistence and AM5 SMBus

The two platform facts every subsystem in this repo is shaped by. Read these
before changing anything on the machine; the per-subsystem READMEs assume them.

- [SteamOS persistence](#steamos-persistence)
- [SMBus and I2C on AM5](#smbus-and-i2c-on-am5)

## SteamOS persistence

SteamOS 3.x boots a read-only btrfs root from an A/B pair. An update writes a whole new image to the inactive slot and boots into it, so anything in `/usr`, `/opt` or `/usr/local` is gone after the next update. That includes anything `pacman -S` installed after `steamos-readonly disable`.

**Btrfs confirmed** (`findmnt -no SOURCE,FSTYPE /` → `/dev/nvme0n1p5 btrfs`). Note that on this box `steamos-readonly status` currently reports **disabled**, so the root is mounted `rw` — that is a local change, not the stock state, and it does not make anything survive an update.

- `/home` — separate partition, always survives.
- `/etc` — overlayfs with its upper layer in `/var/lib/overlays/etc/upper` (confirmed via `findmnt /etc`). Survives reboots always, and is writable even when `steamos-readonly` is enabled. Since SteamOS 3.6 only an allowlisted subset carries into a new OS version.
- `/etc/atomic-update.conf.d/` — the supported way to add paths to that allowlist, and it has to name the `systemctl enable` symlinks too, not just the unit files. Read `example-additional-keep-list.conf` on the machine for the syntax; it is not documented publicly.
- **The default keep list is `/usr/lib/rauc/atomic-update-keep.conf`** — read it before assuming anything in `/etc` persists across an update. It covers `/etc/systemd/system/*.service`, `*.socket`, `*.mount`, `*.wants/**`, `*.requires/**`, NetworkManager connections, sddm.conf.d, ssh host keys, passwd/group/shadow and `/etc/atomic-update.conf.d/*.conf` itself (so allowlist entries are self-preserving).
- **`/etc/modprobe.d` is _not_ on that list**, nor is `/etc/modules-load.d`, `/etc/udev/rules.d` or `/etc/default/grub*`. Anything dropped there needs its own `atomic-update.conf.d` entry or it vanishes on the next A/B update, silently and with no obvious symptom.
- **This bites third-party tools that write to `/etc` on your behalf, not just things set up here.** LACT's "enable overclocking" button writes `/etc/modprobe.d/99-amdgpu-overdrive.conf` and is otherwise correct; the 1 Aug 2026 update ate it, and the only symptom was LACT offering to enable overclocking again. Assume any tool that offers to write a `/etc` file needs checking against the keep list. Now handled by [hardware/gpu/](../hardware/gpu/README.md).
- **A self-heal that restores the wrong variant is worse than one that fails.** `hardware/rgb/` keeps a marker file recording whether SMBus access was granted; the marker was not allowlisted, so an update took it and the boot self-heal quietly reinstalled the rule in its `--no-i2c` form — every unit reported healthy and the only symptom was the RAM lighting up again. Allowlist the state a self-heal reads, not just the files it writes.
- **`/var/lib/steamos-atomupd/etc_backup/*.tar.xz` is how to prove it after the fact.** SteamOS snapshots `/etc` immediately before discarding it, so `tar tf` on the newest tarball lists exactly what the last update took. This is the fastest way to answer "did this get wiped, or did I never set it?". Allowlist the *specific file*, never the directory — an allowlisted path shadows all future upstream versions of it forever. The one exception is a directory nothing upstream ships into and no pacman package owns, where there is no version to shadow: `/etc/coolercontrol/*` is allowlisted wholesale for exactly that reason, because the daemon creates its own state files there and naming them individually would silently lose any a future release adds.
- Don't edit `/etc/default/grub-steamos` to add kernel parameters: it is a Valve-shipped file in the overlay's lower layer, so editing it permanently shadows their future GPU/platform tuning. `grub-mkconfig` sources `/etc/default/grub.d/*.cfg` first (line 163 of the script), which is the clean place for additions. Better still, if the setting is a module parameter, use `/etc/modprobe.d` — no `grub.cfg` regeneration needed.
- Prefer solutions with no package dependencies. Python 3 is in the base image. `i2c-tools` is not.
- Anything installed with pacman needs an idempotent install script that gets re-run after every OS update.
- `/usr/lib/systemd/system-sleep/` is unusable here (read-only rootfs). For resume hooks use a systemd unit in `/etc/systemd/system` with `After=sleep.target` and `WantedBy=sleep.target`. `sleep.target` covers suspend, hibernate, hybrid-sleep and suspend-then-hibernate; `suspend.target` only covers plain suspend.

## SMBus and I2C on AM5

- **The SMBus is blocked by ACPI out of the box, and this is the reason a tool "doesn't detect" RAM on this board.** The firmware declares an OperationRegion (`\GSA1.SMBI`) over `0x0B00-0x0B0F`, and the kernel default `acpi_enforce_resources=strict` makes `i2c-piix4` back off rather than share it: the module loads and registers **zero** adapters. Boot with `acpi_enforce_resources=lax` to get them. Installed by [hardware/sensors/](../hardware/sensors/README.md#the-fch-smbus-is-blocked-by-acpi); it is a boot parameter only, not settable at runtime.
- Once it works, `i2c-piix4` registers **several** adapters (`SMBus PIIX4 adapter port N at 0bXX`). Only one carries the DIMMs.
- To find that port without generating any bus traffic, list what the SPD driver bound: `ls /sys/bus/i2c/drivers/spd5118/` returns entries like `0-0050`, `0-0051`, where the prefix is the bus number. Kernel patches from mid-2024 auto-instantiate `spd5118` on the correct piix4 port, so this is authoritative rather than a guess. Anything else on the DIMMs, including the Fury RGB controllers at `0x60-0x67`, is on that same bus.
- **`i2c-dev` is loaded, and it is not a safety layer.** An earlier revision of this note claimed it was deliberately left unloaded so no userspace tool could reach the bus. That is wrong: SteamOS loads it itself via `/usr/lib/modules-load.d/ddcutil.conf` and `fwupd-i2c.conf`, so every `/dev/i2c-*` node exists including the SPD bus. See [hardware/sensors/](../hardware/sensors/README.md#why-this-is-handled-carefully) for the three mitigations that do apply.
- **This platform has no hardware SPD write protection.** Intel's `i2c-i801` honours an SPD write disable bit in the SMBus host config register (`SMBHSTCFG_SPD_WD`) that BIOS can set, blocking host writes to `0x50-0x57` in hardware. `i2c-piix4` has no equivalent and calls `i2c_register_spd_write_enable()` unconditionally. The DDR5 SPD EEPROMs here are always writable from the host, so any tool that scans or writes SMBus can kill the RAM. This is why [hardware/rgb/](../hardware/rgb/README.md) is as paranoid as it is.
- `spd5118` (hwmon) binds the DDR5 SPD hubs at `0x50-0x57`. While bound, `ioctl(I2C_SLAVE)` on those addresses returns `EBUSY`, and that is the main thing protecting them. Never unbind it. `i2cdetect` prints `UU` for addresses a driver owns.
- On DDR5 the module temperature sensor lives **inside** the SPD hub, so anything reading DIMM temps is talking to `0x50-0x57`. Through the `spd5118` driver that is fine. Through a userspace tool on `/dev/i2c-*` it is not.
- Never run `i2cdetect -y <bus>` bare: its auto mode quick-writes to every address outside `0x30-0x37` and `0x50-0x5F`. Restrict it, and force read-byte probes: `i2cdetect -y -r <bus> <first> <last>`.
- `dmidecode -t 17` enumerates the DIMMs with zero bus traffic. A baseline is committed at `hardware/sensors/baseline/dmidecode-t17.txt` and `hardware/sensors/bin/spd-check.sh` diffs the live DMI against it; a change in reported size, speed, part number or serial is the early warning that SPD has been corrupted.

## Related reading

| Topic | Where |
| --- | --- |
| Why no SteamOS kernel can do 4K120 over native HDMI, and how the FRL build survives updates | [hardware/kernel/](../hardware/kernel/README.md) |
| The TV is this machine's only console — modeset safety rules | [hardware/display/](../hardware/display/README.md#warning-the-tv-is-this-machines-only-console) |
| MediaTek MT7902 Wi-Fi/Bluetooth on this board | [hardware/bluetooth/](../hardware/bluetooth/README.md) |
| SMBus/I2C access control and the DIMM-bricking hazard | [hardware/rgb/](../hardware/rgb/README.md#access-control-and-why-the-shipped-rules-are-not-used) |
