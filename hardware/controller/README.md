# Controllers

Notes on game controllers on this machine. Nothing is installed by this directory — there is no `install.sh`, because nothing here needs local configuration.

- [Steam Controller (2026)](#steam-controller-2026)
- [`hid-steam`: Valve's kernel has the IDs, mainline does not — now backported](#hid-steam-valves-kernel-has-the-ids-mainline-does-not--now-backported)
- [Related](#related)

## Steam Controller (2026)

Works. Codename **Triton**, following `gordon` (the 2015 Steam Controller) and `neptune` (the Deck).

Wired, the controller enumerates as `28de:1302`. Over the wireless puck it is `28de:1304`, which exposes seven interfaces:

```
Bus 001 Device 008: ID 28de:1304 Valve Software Steam Controller Puck
```

Both the controller and the puck take firmware updates through Steam, delivered inside the Steam client package rather than through SteamOS. The blobs live in `~/.local/share/Steam/bin/hardwareupdater/` as `IBEX_FW_*.fw` and `PROTEUS_FW_*.fw`; the hex in each filename is the build time as a Unix timestamp, so `date -d @$((16#6A628345))` dates a blob directly. Keep the client current — firmware arrives only with it, and a client that cannot update cannot deliver firmware either.

## `hid-steam`: Valve's kernel has the IDs, mainline does not — now backported

Valve added the 2026 controller to `hid-steam` in **6.18.42** (SteamOS 3.8, 2026-08-08). Mainline **7.2-rc6 has not**, so the FRL kernel shipped without it:

| Kernel | `hid-steam` IDs |
| --- | --- |
| `6.18.42-valve2-1-neptune-618` | `1302` wired, `1303` Bluetooth, `1304` puck, `1305`, plus the three legacy ones |
| `7.2.0-rc6-frlprobe` (stock mainline) | `1205` Deck, `1142`/`1102` 2015 controller — nothing else |

Without it every puck interface falls through to `hid-generic` and `hid_steam` never loads:

```
/sys/bus/hid/devices/0003:28DE:1304.0002  driver: hid-generic
```

Steam drives the controller over hidraw regardless, so nothing is broken — but there is no in-kernel gamepad node, which is what anything that is not Steam would use.

### Backported as patches 0007-0008 (2026-08-08)

Valve's `hid-steam.c` from `6.18.42-valve2` **compiles against 7.2-rc6 with no source changes**, so the FRL kernel can carry it. See [hardware/kernel/patches/](../kernel/patches/README.md) for provenance and the trap in `hid-ids.h` (take the four defines, never the whole header).

What the driver adds beyond the IDs — this is why adding the IDs alone would have been worse than useless, binding `hid-steam` to a device it could not parse:

```
steam_do_ibex_input_event     steam_exchange_report
steam_do_ibex_sensors_event   steam_send_report_id / steam_recv_report_id
steam_sensor_open / _close    steam_coalesce_rumble_cb
```

Codenames match the firmware blobs Steam ships: `IBEX_FW_*.fw` is the controller (`0x1302`), `PROTEUS_FW_*.fw` the puck (`0x1304`).

**Status: confirmed working on 2026-08-08.** All nine puck interfaces moved from `hid-generic` to `hid-steam`, and `/dev/input/js*` gamepad nodes appeared:

```
0003:28DE:1304.0002 ... .0010   ->  hid-steam
hid-steam 0003:28DE:1304.0004: Steam wireless receiver connected
/dev/input/js0, js1             ->  "Valve Software Steam Controller Puck"
```

Two things bite on the way in, both recorded because neither is the driver's fault:

- **The rootfs is read-only again after a SteamOS update.** `/usr/lib/modules` lives on it, so an install needs `steamos-readonly disable` and a relock afterwards. Do not assume it is unlocked because it was last time.
- **The module can fail to load with `-EINVAL` and `failed to validate module [hid_steam] BTF: -22`.** That is the BTF debug-info section, which `pahole` can emit with an enum the kernel's validator rejects. BTF is used only by BPF tooling, so `objcopy --remove-section=.BTF` on the `.ko` fixes it at no cost.

Re-check after any kernel rebase:

```bash
modinfo -F alias hid-steam | grep 130
```

Drop both patches once Valve post the driver to linux-input and it merges.

## Related

- The **controller wake from sleep** item in the root README is about the DualSense over Bluetooth. There is an upstream report that the 2026 controller and its puck also fail to wake from suspend ([ublue-os/bazzite#4873](https://github.com/ublue-os/bazzite/issues/4873)) — **not tested on this machine**, noted only because it touches the same open item.
