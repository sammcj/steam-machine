# USB — one bad port taking the whole controller down

Symptom: the mouse, keyboard and headset all drop out together and take a long time to come back. It reads like a wireless reception problem, and for a while it was diagnosed as one. It is not — or not only.

Fix: a udev rule that stops the xHCI controller from wedging, plus a watchdog that rebuilds it if it does. `usb-reset` is the manual front end.

## The topology is the amplifier

Every 2.4 GHz receiver has to sit near the couch to get reception, so they all hang off one hub on a long cable. That hub is plugged into a rear USB 3.2 port, but only the USB 2.0 half of that connector is in use — `usb5-port2` is `configured` while its SuperSpeed peer `usb6-port2` reads `not attached`, and no device has ever enumerated at SuperSpeed on this machine. So everything shares one 480 Mbit/s link:

```
usb5  (0000:12:00.4, 480M, 2 root ports — only port 2 used)
└── 5-2      VIA VL817  2109:2817   multi-TT, self-powered, per-port power + OC
    ├── 5-2.1    214b:7250          SINGLE-TT, bus-powered, 100 mA
    │   ├── 5-2.1.1  1908:0226      card reader (sdc, 0 B, no media)
    │   ├── 5-2.1.2  1532:00b8      Razer Viper V3 HyperSpeed      12M
    │   ├── 5-2.1.3  1908:0226      card reader (sdd, 0 B, no media)
    │   └── 5-2.1.4  VL812 2109:2812  SINGLE-TT
    │       ├── 5-2.1.4.1  10f5:2242  Turtle Beach Stealth 600P    12M, isochronous
    │       └── 5-2.1.4.4  24f0:0141  Das Keyboard                 12M
    ├── 5-2.3   046d:c52b            Logitech Unifying (K400 Plus) 12M
    └── 5-2.4   0bda:8153            Realtek r8152 USB gigabit LAN
```

Two things follow from that shape, and neither is a driver bug.

**A hub is a shared reset domain.** There is no per-port fault isolation for this failure class. When a port reset fails the core escalates to resetting the parent hub, which disconnects every sibling. Straight from the log on 2026-09-05, one second apart:

```
22:40:33  usb 5-2.1-port3: cannot reset (err = -71)   ×5
22:40:33  usb 5-2.1-port3: Cannot enable. Maybe the USB cable is bad?
22:40:33  usb 5-2: USB disconnect, device number 2
22:40:33  usb 5-2.1, 5-2.1.1, 5-2.1.3, 5-2.1.4, 5-2.2, 5-2.4 ... all gone
```

`5-2.1-port3` is an **empty card reader slot**. It took down the mouse, both keyboards, the network adapter and the storage. The 20:57 storm in the previous boot started on the mouse port instead. The headset dongle was not the trigger in either case — any device on that link can start it.

`-71` is `EPROTO`: bit-stuffing/CRC errors on the wire. It is a physical-layer error, not a device-state one. A link that throws EPROTO storms *and* cannot train SuperSpeed is one fact, not two: the run to the couch is marginal.

**The headset shares a transaction translator with a keyboard.** `5-2.1.4` is single-TT, so every full-speed device beneath it shares one TT budget — and beneath it are the Turtle Beach dongle doing isochronous audio and the Das Keyboard. That is a dropout cause on its own, independent of the WirePlumber idle-suspend issue already fixed in [hardware/audio/](../audio/README.md).

## What actually locked the machine up

The storm is recoverable. What was not, before this subsystem, is the second-order failure.

A wedged xHC command ring makes the *next* runtime-suspend attempt time out inside `xhci_suspend()`'s 20 ms `STS_SAVE` handshake:

```
hub 5-2:1.0: config failed, can't get hub status (err -5)
xhci_hcd 0000:12:00.4: Controller Save State failed -110
xhci_hcd 0000:12:00.4: PM: suspend_common(): xhci_pci_suspend returns -110
xhci_hcd 0000:12:00.4: can't suspend (hcd_pci_runtime_suspend returned -110)
```

That sets `dev->power.runtime_error`. From then on `rpm_resume()` and `rpm_check_suspend_allowed()` return `-EINVAL` unconditionally and `power/runtime_status` reads `error` ahead of the real state (`drivers/base/power/{runtime,sysfs}.c`).

Three things about that flag, all verified on this machine rather than assumed:

- **It cannot be cleared from sysfs.** `runtime_status` is `DEVICE_ATTR_RO`. The flag is only cleared inside `__pm_runtime_set_status()`, which is kernel-internal.
- **A driver rebind does not reliably clear it.** Measured: unbind/rebind of `xhci_hcd` returned the bus but left `runtime_status=error`.
- **It survives a full system suspend/resume.** The machine slept and woke at 23:10–23:12 with the flag still set.

Only destroying and re-creating the `pci_dev` clears it — `echo 1 > .../remove` followed by `echo 1 > /sys/bus/pci/rescan`.

There are no xHCI quirks in mainline for this silicon. `xhci-pci.c`'s AMD blocks cover Raven, Renoir, Promontory and the SNPS parts; the Raphael/Granite Ridge IDs (`1022:15b6/15b7/15b8`) appear nowhere. `XHCI_SNPS_BROKEN_SUSPEND` is the one escape hatch from that handshake and it does not apply here.

## The fix, in two halves

**Prevention.** `udev.rules.d/60-steam-machine-usb.rules` pins `power/control=on` on every xHCI controller at `add|bind`. A controller that never runtime-suspends never runs the save-state path, so it cannot reach the error state at all. Matched on PCI class `0x0c0330` rather than address: this board has already renumbered its USB controllers once (`11:00.4` → `12:00.4`), which is why [hardware/audio/](../audio/README.md) still carries a stale address.

**Recovery.** `steam-machine-usb-watchdog.service` polls every 5 s and runs `bin/usb-reset.sh --broken` when it finds a controller that is actually broken. Prevention only helps from the moment the rule is in place, and nothing stops a hung command ring in the first place.

**What counts as broken is not `runtime_status=error`.** The first version of this watchdog made that mistake and it is worth recording, because the two look identical from a distance. At 23:16 the controller read `error` with all ten of its devices present and working — the flag only means it can never runtime-suspend again, which is exactly what the udev rule wants anyway. Treating it as a fault triggered a remove/rescan on a healthy bus and briefly took every device down for no reason.

The test is structural instead, and lives in one place (`usb-reset.sh --list-broken`) so the code that decides to act and the code that decides it worked cannot disagree:

- the controller is not bound to `xhci_hcd`, or
- it is bound but has no USB buses registered, or
- a hub beneath it enumerated but failed to configure — `bDeviceClass=09` with `maxchild=0` and no driver on its interface.

That third one is the signature of the real failure. A healthy hub here reads `class=09, maxchild=4, driver=hub`; the 22:40 log line `hub 5-2:1.0: config failed, can't get hub status (err -5)` is a hub left at `maxchild=0` with every device behind it unreachable. `runtime_status` is still reported by `status`, as information.

The reset escalates: unbind/rebind first, then PCI remove + rescan only if the controller is still unhealthy. Both are bounded by polling for the buses to come back rather than by a fixed sleep, and `remove` runs under `timeout` because `xhci_pci_remove` talks to a controller that may be hard-hung.

It gives up after a few recoveries in a window and says so, loudly. A controller that re-wedges immediately after every reset is a cabling or hardware fault, and hammering it with remove/rescan makes it worse.

## Usage

```
usb-reset              reset every xHCI controller
usb-reset status       report controller state (no root needed)
usb-reset broken       reset only controllers that are actually broken
usb-reset watchdog     what the watchdog has been doing
```

`usb-reset --controller 0000:12:00.4 --dry-run` and `--force` are passed straight through.

Two guards refuse a reset, both overridable with `--force`: a mounted filesystem on the controller, and the default route living on it. The second matters here because there is a USB NIC (`5-2.4`) on the same controller as everything else — it is not currently the default route (that is the onboard `enp9s0` on `09:00.0`), but it could become one.

## Verified

Watchdog exercised against a genuinely broken controller on 2026-09-05, not a simulated one:

```
23:16:09  wedged: 0000:12:00.4 -- recovering (attempt 1/5 in window)
23:16:09  ==> 0000:12:00.4: unbind/rebind xhci_hcd
23:16:27  [warn] 0000:12:00.4: still unhealthy after rebind (status=error)
23:16:27  ==> 0000:12:00.4: PCI remove + rescan
23:16:30  ==> 0000:12:00.4: recovered by remove/rescan (status=active)
```

21 seconds, no reboot, all ten devices back. The rebind tier failing exactly as predicted is the useful part — it is why the remove/rescan tier exists.

The same run is also where the `runtime_status=error` false positive was found: the bus it "recovered" had not actually been down. The recovery path is proven; the trigger that fired it was wrong and has been narrowed to the structural test above.

## Rejected

- **`early_stop=1` on the storming ports.** Per-port, caps enumeration at two attempts instead of hundreds, which would bound the stall. Rejected because the latch is one-way: `hub.c:5836` skips *all* port events once `ignore_event` is set, so a replug does not clear it — the replug is the event being ignored. Clearing it needs `echo 0 > early_stop`, a re-enumeration, then `echo 1` to re-arm; writing `0` then `1` back to back leaves the port deaf. A port that needs a manual write to come back is worse than a slow one on a machine whose only console is a TV.
- **`xhci_hcd.quirks=0x80`** (`XHCI_RESET_ON_RESUME`). Since ~5.7 that quirk also blocks runtime suspend entirely, so it "fixes" this by the same mechanism as the udev rule — but it is `0444`, so cmdline-only, and it adds a full host-controller reset on every system resume. Redundant and more invasive.
- **`usbcore.autosuspend=-1`.** Governs USB devices, not the PCI host function. Wrong layer for this failure.

## Still outstanding — physical, not software

None of the above makes the link to the couch any better. In rough order of value:

1. **Get the card readers and the USB NIC off the couch link.** Two empty card reader slots started the outage that prompted all this, and there is already an onboard NIC (`enp9s0`) carrying the default route. Neither needs to be near the couch.
2. **Move the headset dongle up to a port on `5-2` directly.** It is currently three hubs deep, sharing a single TT with the Das Keyboard. `5-2` is the multi-TT self-powered VL817 and `5-2-port2` is free. Same hub, same reception, own TT, two fewer hops.
3. **Fix the cable.** The EPROTO storms and the untrained SuperSpeed link are the same fact. USB 2.0 high-speed is speced to 5 m of good cable and long USB-A extensions are usually 2.0-only and out of spec.

## Files

| Path | Survives an A/B update? |
|---|---|
| `/etc/udev/rules.d/60-steam-machine-usb.rules` | No — keep-listed, plus `--boot` self-heal |
| `/etc/atomic-update.conf.d/steam-machine-usb.conf` | Yes, the keep list itself is allowlisted |
| `/etc/systemd/system/steam-machine-usb.service` | Yes, on the default keep list |
| `/etc/systemd/system/steam-machine-usb-watchdog.service` | Yes, on the default keep list |

`install.sh --status` reports all of it. `install.sh --boot` restores anything missing and re-applies the pin to the live controllers, so a restored rule takes effect that boot rather than the next one.
