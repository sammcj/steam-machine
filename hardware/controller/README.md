# Controllers

Notes on game controllers on this machine. Nothing is installed by this directory — there is no `install.sh`, because nothing here needs local configuration.

- [Steam Controller (2026)](#steam-controller-2026)
- [`hid-steam`: Valve's kernel has the IDs, mainline does not](#hid-steam-valves-kernel-has-the-ids-mainline-does-not)
- [Related](#related)

## Steam Controller (2026)

Works. Codename **Triton**, following `gordon` (the 2015 Steam Controller) and `neptune` (the Deck).

Wired, the controller enumerates as `28de:1302`. Over the wireless puck it is `28de:1304`, which exposes seven interfaces:

```
Bus 001 Device 008: ID 28de:1304 Valve Software Steam Controller Puck
```

Both the controller and the puck take firmware updates through Steam, delivered inside the Steam client package rather than through SteamOS. The blobs live in `~/.local/share/Steam/bin/hardwareupdater/` as `IBEX_FW_*.fw` and `PROTEUS_FW_*.fw`; the hex in each filename is the build time as a Unix timestamp, so `date -d @$((16#6A628345))` dates a blob directly. Keep the client current — firmware arrives only with it, and a client that cannot update cannot deliver firmware either.

## `hid-steam`: Valve's kernel has the IDs, mainline does not

Valve added the 2026 controller to `hid-steam` in **6.18.42** (SteamOS 3.8, shipped 2026-08-08). Mainline **7.2-rc6 has not**, so this is a Valve backport and a live cost of running the FRL kernel:

| Kernel | `hid-steam` IDs |
| --- | --- |
| `6.18.42-valve2-1-neptune-618` | `1302` wired, `1303` Bluetooth, `1304` puck, `1305`, plus the three legacy ones |
| `7.2.0-rc6-frlprobe` (mainline) | `1205` Deck, `1142`/`1102` 2015 controller — **and nothing else** |

On the FRL kernel every puck interface therefore falls through to `hid-generic` and `hid_steam` is not even loaded:

```
/sys/bus/hid/devices/0003:28DE:1304.0002  driver: hid-generic
```

Steam drives the controller over hidraw regardless, so nothing is broken — but there is no in-kernel gamepad node while on the FRL kernel, and there is nothing droppable in `/etc` that fixes it. Either boot stock, or carry the IDs as a patch on the next kernel rebuild. Re-check after each rebase:

```bash
modinfo -F alias hid-steam | grep 130
```

## Related

- The **controller wake from sleep** item in the root README is about the DualSense over Bluetooth. There is an upstream report that the 2026 controller and its puck also fail to wake from suspend ([ublue-os/bazzite#4873](https://github.com/ublue-os/bazzite/issues/4873)) — **not tested on this machine**, noted only because it touches the same open item.
