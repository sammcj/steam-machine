# RGB lighting (off)

RGB is tacky and distracting in a living room. This subsystem turns every LED
in the build off and keeps it off across reboots and SteamOS A/B updates.

```sh
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh
./install.sh --status
```

## The GPU has no RGB controller

This is the thing worth writing down, because every obvious approach to it is
wrong.

The card is an **XFX Mercury RX 9070 XT OC Gaming Edition** (`RX-97TRGBBB9`),
PCI `1002:7550`, subsystem `1eae:8811`. OpenRGB will never detect it as a GPU,
and no amount of configuration changes that.

Cards OpenRGB *does* support — Sapphire Nitro+, ASUS TUF, Gigabyte AORUS,
PowerColor Red Devil, all of which have RDNA4 entries compiled into the 1.0rc3
build already installed here — carry a real RGB microcontroller on one of the
I²C buses the GPU exposes. This card carries nothing. Measured 2026-08-02, all
six buses belonging to `0000:03:00.0`:

| Bus            | Name                     | Devices |
| -------------- | ------------------------ | ------- |
| `i2c-5`,`i2c-6`  | `AMDGPU SMU 0` / `SMU 1`     | none    |
| `i2c-7`…`i2c-10` | `AMDGPU DM i2c hw bus 0`–`3` | none    |

Reproduce with `i2cdetect -y -r 5` and so on; `install.sh --status` prints the
bus list. Nothing on USB or hidraw belongs to the card either.

There is no controller because there is nothing to control. XFX's own
description is *"a full-length 5-volt ARGB element across the shroud"* driven
by a supplied **sync cable** — the strip is a dumb WS2812-style slave with an
ARGB **input**, not a host-addressable device. Unconnected, it runs a hardcoded
rainbow from a small onboard driver, which is what makes it look like something
software ought to be able to reach.

Upstream request [#5154](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/5154)
is for this exact card (it quotes subsystem `1EAE:8811`) and has sat open with
its "device captures" section blank. That is not neglect — there is nothing to
capture.

### So the GPU is driven through the motherboard

Plug the XFX sync cable into one of the three **ARGB_V2** headers on the B850M
FORCE WIFI6E V2 (3-pin 5V/Data/GND, 4-pin body with position 3 keyed out, 3 A
and 256 LEDs max per header). The strip then becomes a zone of the controller
OpenRGB already detects:

```
1: B850M FORCE WIFI6E V2   IT5711-GIGABYTE V1.0.29.6
   Zones: ARGB_V2_1 ARGB_V2_2 ARGB_V2_3 LED_C
```

`bin/rgb-off.sh` sizes and blanks **all three** ARGB headers, so it does not
matter which one the cable ends up in — that gets decided with the side panel
off, not here.

### LED count

A dumb ARGB strip reports nothing back, so its length cannot be read, only
declared. `ARGB_LEDS` defaults to **64**:

- overshooting is harmless — surplus bytes clock off the end of the chain and
  are dropped;
- undershooting leaves the tail of the strip lit.

Hence the generous default. If the strip turns out to be longer, raise it
(`ARGB_LEDS=128 ./bin/rgb-off.sh`) — the ceiling is 256. To find the real
count, `./bin/rgb-off.sh --colour FF0000` and see how far along the shroud the
red reaches.

## Static, not Direct

The IT5711 supports both. **Direct** is host-driven: the controller holds the
last frame it was sent and nothing else, so it depends on something still
running. **Static** is committed to the controller and survives OpenRGB
exiting, the session ending, and a power cycle.

Everything here uses Static. The systemd units are therefore a safety net for
the case where firmware reasserts its own defaults, not the mechanism — which
is why a failure in either is cosmetic and must never block boot.

## Access control, and why the shipped rules are not used

OpenRGB needs non-root access to the ITE HID node and, for the RAM, to the FCH
SMBus. Upstream ships a 158 KB `60-openrgb.rules` covering every device the
project has ever supported. There is already a copy on this machine at
`/usr/lib/udev/rules.d/60-openrgb.rules`. It is not used here, for two reasons.

**It is in `/usr`, and owned by no package.** `pacman -Qo` reports no owner and
the file is `deck:deck` — it was dropped there by hand. `/usr` is the one tree
a SteamOS A/B update replaces wholesale, so that copy is already living on
borrowed time. Consider removing it; nothing in this repo depends on it.

**It grants uaccess to every I²C bus on the system:**

```
KERNEL=="i2c-[0-99]*", TAG+="uaccess"
```

On this board that includes the FCH SMBus, where the DDR5 SPD EEPROMs sit at
`0x50`–`0x57`. `i2c-piix4` has no equivalent of Intel's SPD write-disable bit
and calls `i2c_register_spd_write_enable()` unconditionally, so those EEPROMs
are permanently host-writable and a bad write bricks the DIMMs — see
[hardware/sensors/](../sensors/README.md) and `hardware/sensors/bin/spd-check.sh`.
Handing that to every process in the seat session, forever, to light up a
graphics card is a bad trade.

`udev.rules.d/60-steam-machine-rgb.rules` replaces it with two explicit
stanzas, and installs to `/etc`, which survives reboots unconditionally.

Each stanza carries a distinguishing tag (`Gigabyte_RGB_Fusion_2_USB`,
`Steam_Machine_SMBus`) purely so the narrowing can be proven rather than
assumed — otherwise upstream's blanket rule would mask a failure here and the
whole exercise would be imaginary:

```sh
udevadm test /sys/class/hidraw/hidraw5 | grep Gigabyte_RGB_Fusion_2_USB
udevadm test /sys/class/i2c-dev/i2c-2  | grep Steam_Machine_SMBus
```

Note the Gigabyte board reports USB **048d:5711**, which upstream's file does
*not* list (it has `048d:8297` and `048d:5702`). Access to it currently happens
to be granted by a stale `uaccess` tag in the udev database that no live rule
reproduces — `udevadm test` on the hidraw node matched nothing that set it.
That is luck, not configuration, and it would not survive a database rebuild.

### `--no-i2c`, and why it needs `--drop-upstream-rules`

`./install.sh --no-i2c` omits the SMBus stanza entirely. The RAM's RGB then
becomes unreachable — but since Static persists in the controller, RAM that has
already been blanked once stays blanked. That is the safer end state: run the
default install, confirm the LEDs are out, then drop the standing SPD exposure.

**`--no-i2c` alone does nothing while `/usr/lib/udev/rules.d/60-openrgb.rules`
exists** — its blanket rule re-grants every bus regardless of what this repo
installs. Verified: with the stanza correctly stripped from the installed rule,
`/dev/i2c-2` still carried the ACL and OpenRGB still detected the RAM.

`install.sh` therefore refuses to pretend. `--no-i2c` warns when it is being
overridden, and `--status` reports the upstream file as `PRESENT … overrides
--no-i2c`. The full sequence is:

```sh
sudo -A ./install.sh                        # blank everything, RAM included
sudo -A ./install.sh --drop-upstream-rules  # remove the catch-all (backed up)
sudo -A ./install.sh --no-i2c               # now actually effective
```

`--drop-upstream-rules` is deliberately never part of a normal install: it
deletes a file this repo did not create. It refuses if pacman turns out to own
it, copies it to `~/.cache/steam-machine-rgb/` first, and unlocks the rootfs
only for that one operation. The cost is that OpenRGB then reaches only the two
devices named in our own rule — fine here, but it would silently drop any RGB
peripheral added later.

### No group changes, and no `hid` group

There is no `hid` group on this system — `/dev/hidraw*` is `root:root 0660`
with access granted by a POSIX ACL, not group membership. An `i2c` group does
exist (gid 964) and `deck` is not in it, but adding it would be strictly worse
than the udev rule: group membership is unconditional and machine-wide, whereas
`uaccess` grants the ACL only to whoever owns the active seat and revokes it on
logout. `/etc/group` *is* on the SteamOS keep list, so a group change would
persist — it is just the wrong tool. Verify with `getfacl /dev/hidraw5`.

## What survives what

| Path                                          | Reboot | SteamOS A/B update      |
| --------------------------------------------- | ------ | ----------------------- |
| `/etc/udev/rules.d/60-steam-machine-rgb.rules` | yes    | only via the keep entry |
| `/etc/atomic-update.conf.d/steam-machine-rgb.conf` | yes | yes (default keep list) |
| `/etc/systemd/system/steam-machine-rgb.service`| yes    | yes (default keep list) |
| `~/.config/systemd/user/…`, this repo          | yes    | yes (`/home` untouched) |
| `/usr/lib/udev/rules.d/60-openrgb.rules`       | yes    | **no** — wiped          |

The keep entry names the **specific file**, never `/etc/udev/rules.d` as a
directory: an allowlisted path shadows all future upstream versions of it
forever, and SteamOS ships its own rules into that directory.

`install.sh --boot` reinstalls both `/etc` files if they are missing or
modified, so the subsystem self-heals even if the keep entry itself was absent
when an update ran. It also reloads udev *and* re-triggers the affected
subsystems — a rules reload alone only affects the next uevent, so without the
trigger a restored rule would do nothing until the following reboot.

## Units

| Unit | Scope | Job |
| ---- | ----- | --- |
| `steam-machine-rgb.service` | system | `install.sh --boot` — put `/etc` back |
| `steam-machine-rgb-off.service` | user | `rgb-off.sh --boot` — blank the LEDs |

Split because OpenRGB is a per-user Flatpak reached through the seat's uaccess
ACL: root cannot `flatpak run` it, and the `/etc` repair cannot be done without
root. The user unit polls for up to 60 s because the ACL is applied as the seat
session activates, which races it.

```sh
systemctl status steam-machine-rgb.service
systemctl --user status steam-machine-rgb-off.service
```

## Known noise

Every OpenRGB invocation prints an HTML block saying the udev rules are not
installed. It is a false positive: the Flatpak sandbox has its own `/usr` and
cannot see the host's rules files. `rgb-off.sh` filters it. Detection working
at all is the actual proof the rules are in place.

## The abandoned approach

Before this subsystem existed, a bespoke Python SMBus writer for the Fury DIMMs was designed in detail (`git log -- hardware/ram/` for the plan). None of it was built, and it is worth knowing why, because the plan reads convincingly:

- Its premise was that OpenRGB was picking the wrong `i2c-piix4` port. It was not — there were **no ports at all**, because the firmware declares an ACPI OperationRegion over the SMBus range and `acpi_enforce_resources=strict` made `i2c-piix4` register zero adapters. Fixed in `hardware/sensors/`, after the plan was written.
- Its central safety rule was "never install or run OpenRGB on this machine". That is the opposite of what shipped: OpenRGB reaches the DIMMs fine once the bus exists, and Static mode commits to the controller so it survives OpenRGB exiting.

The one durable warning from it is already captured above: SPD EEPROMs on this board have no write protection, so treat any tool that writes SMBus with suspicion — `kfrgb` in particular still writes during detection even under `--simulation`.
