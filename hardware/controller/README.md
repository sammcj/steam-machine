# Controllers

Notes on game controllers on this machine. Nothing is installed by this directory — there is no `install.sh`, because nothing here needs local configuration.

- [Steam Controller (2026)](#steam-controller-2026)
- [Kernel `hid-steam` has no IDs for the 2026 controller](#kernel-hid-steam-has-no-ids-for-the-2026-controller)
- [Related](#related)

## Steam Controller (2026)

Works. Codename **Triton**, following `gordon` (the 2015 Steam Controller) and `neptune` (the Deck).

Wired, the controller enumerates as `28de:1302`. Over the wireless puck it is `28de:1304`, which exposes seven interfaces:

```
Bus 001 Device 008: ID 28de:1304 Valve Software Steam Controller Puck
```

Both the controller and the puck take firmware updates through Steam, delivered inside the Steam client package rather than through SteamOS. The blobs live in `~/.local/share/Steam/bin/hardwareupdater/` as `IBEX_FW_*.fw` and `PROTEUS_FW_*.fw`; the hex in each filename is the build time as a Unix timestamp, so `date -d @$((16#6A628345))` dates a blob directly. Keep the client current — firmware arrives only with it, and a client that cannot update cannot deliver firmware either.

## Kernel `hid-steam` has no IDs for the 2026 controller

`hid-steam` on the current neptune kernel (`6.16.12-...-neptune-616`) carries three IDs:

```
hid:b0003g*v000028DEp00001205    Steam Deck
hid:b0003g*v000028DEp00001142    2015 Steam Controller, dongle
hid:b0003g*v000028DEp00001102    2015 Steam Controller, wired
```

Neither `1302` nor `1304` is present, so all five puck HID interfaces fall through to `hid-generic`:

```
/sys/bus/hid/devices/0003:28DE:1304.000D  driver: hid-generic
```

Upstream mainline has not added the IDs either. Steam drives the controller over hidraw regardless, so this does not break anything on its own — but it means there is no in-kernel gamepad node, and it would need a kernel change rather than anything droppable in `/etc`. Nothing to do here until upstream moves. Still true as of 2026-08-07.

## Related

- The **controller wake from sleep** item in the root README is about the DualSense over Bluetooth. There is an upstream report that the 2026 controller and its puck also fail to wake from suspend ([ublue-os/bazzite#4873](https://github.com/ublue-os/bazzite/issues/4873)) — **not tested on this machine**, noted only because it touches the same open item.
