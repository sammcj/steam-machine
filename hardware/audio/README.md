# Audio — USB headset dropouts

Turtle Beach Stealth 600P Gen 3, a wireless headset on a 2.4 GHz USB dongle (`10f5:2242`). Symptom: audio drops out every so often during a game, for a second or two, then comes back on its own.

Fix: one WirePlumber drop-in, `wireplumber/51-turtle-beach-no-suspend.conf`, installed to `~/.config/wireplumber/wireplumber.conf.d/`.

## The cause

WirePlumber suspends any idle audio node. `/usr/share/wireplumber/scripts/node/suspend-node.lua`:

```lua
local timeout = tonumber(node.properties["session.suspend-timeout-seconds"]) or 5
```

Five seconds, hardcoded, as the fallback when the property is absent. Suspending sends the node a `Suspend` command, which closes the ALSA device, which tears down the USB isochronous stream. Re-opening it makes the dongle re-establish its 2.4 GHz link to the headset — visible in the kernel log as `cannot set freq 48000 to ep 0x81` — and that re-sync is what you hear.

So any moment a game leaves the sink idle for five seconds — a menu, a loading screen, a quiet scene where the engine tears down its stream — costs a dropout when audio resumes.

Valve do override this, but only for the Deck's internal cards. Both `valve-jupiter` and `valve-fremont` hardware profiles set `session.suspend-timeout-seconds` (3600 on card0, 0 on card1), and both match on:

```
alsa.card_name = "HD-Audio Generic"
```

A USB headset is a different card with a different name, matches neither rule, and inherits the 5 s default. `pw-dump` confirmed the property was absent on both Turtle Beach nodes before the fix.

## The measurement

A/B, playing two seconds of silence to open the device and then sampling `state` while it sat idle:

| | t+4 s | t+6 s | t+10 s | t+36 s |
|---|---|---|---|---|
| Without the drop-in | `idle` | **`suspended`** | `suspended` | — |
| With the drop-in | `idle` | `idle` | `idle` | `idle` |

Suspend lands between t+4 and t+6, which is the 5 s default. With `session.suspend-timeout-seconds = 0` the node stays `idle` indefinitely — `suspend-node.lua` returns early on zero, before it ever arms the timer.

Note that `node.pause-on-idle` is a *different* mechanism and was already `false` on these nodes. It is not sufficient: the suspend hook fires on the `node-state-changed` event regardless of it.

## What it was not

Both worth recording, because both look plausible and cost time:

- **USB autosuspend.** `power/control` is already `on` for the dongle — [system/power/](../../system/power/README.md) pins it deliberately, along with the other input devices on that controller. It cannot runtime-suspend.
- **The dongle dropping off the bus.** Zero kernel USB events across a 69-minute play session (16:41:30 → 17:50:45) that included a reported dropout. The device never left the bus, so nothing at the USB layer was responsible.

## Do not chase the port

Re-seating the dongle produces a trail of alarming kernel messages that are all *consequences* of one thing, and it is easy to read them backwards:

```
17:55:57  usb 1-4: new high-speed USB device number 12      <- 480M, correct
17:56:02  usb 1-4: 2:1: cannot set freq 48000 to ep 0x81
17:56:12  usb 1-4: 2:0: failed to get current value for ch 0 (-110)
17:57:24  usbhid 1-4:1.3: can't add hid device: -110
17:57:24  usb 1-4: USB disconnect, device number 12
17:57:24  usb 1-4: new full-speed USB device number 13      <- 12M is the RETRY
17:57:24  usb 1-4: not running at top speed; connect to a high speed hub
```

The device enumerates at high speed first. It is only after the control transfers time out and the HID probe fails that the USB core resets the port and retries — and the retry lands at full speed. **A 12 Mbps link here is a symptom of failed enumeration, not a bad port or a bad front-panel cable.** `not running at top speed` names the outcome, not the cause.

The `-110` (`ETIMEDOUT`) transfers are the dongle failing to answer while its 2.4 GHz link to the headset is still down — the same window in which its LED has not lit yet.

Full speed is not a bandwidth problem for this stream, either: 48 kHz stereo 24-bit out is 288 bytes/ms and the mono 16-bit mic in is 96 bytes/ms, against roughly 1023 bytes/ms available to a full-speed endpoint. The reason to get back to 480 Mbps is that it indicates a clean enumeration, not that 12 Mbps starves the audio.

`install.sh --status` reports the current link speed for this reason. Read it against the controller, not against 480 — see [Link speed follows the controller](#link-speed-follows-the-controller-not-the-hot-plug) below: 12 Mbps on `11:00.4` is clean, 12 Mbps on `0f:00.0` is a failed retry. When it is a failed retry, re-seat the dongle **with the headset powered off**, so the link is not being negotiated while the kernel is trying to enumerate.

## It takes the controller with it

Worth knowing, and an argument for where the dongle gets plugged in. Every `-110` above is a blocking control transfer with a five-second timeout, and they run back to back — 17:56:02 through 17:57:24, about 90 seconds. The Steam Controller Puck (`1-1`), the Logitech receiver (`1-7`) and the ITE device (`1-8`) all sit on the *same* xHCI controller (`0f:00.0`) as the dongle, so a stalled command queue takes the input devices down with it. Observed directly: controller and headset froze together and recovered together.

Three other xHCI controllers on this board — `11:00.3` (buses 3/4), `11:00.4` (buses 5/6) and `12:00.0` (bus 7) — had nothing on them but root hubs.

**Done:** the dongle now lives on a rear port that enumerates as `5-2`, on controller `11:00.4`. A wedged dongle can no longer stall the controller the input devices are on.

## Link speed follows the controller, not the hot-plug

Every observation, in order:

| When | Port | Controller | Result |
|---|---|---|---|
| Cold boot | `1-2` | `0f:00.0` | **480 Mbps**, no errors |
| Hot-plug | `1-3` | `0f:00.0` | fail → retry → 12 Mbps |
| Hot-plug | `1-4` | `0f:00.0` | fail → retry → 12 Mbps |
| Hot-plug | `5-2` | `11:00.4` | fail → retry → 12 Mbps |
| **Cold boot** | `5-2` | `11:00.4` | **12 Mbps, zero errors, first try** |

That last row was predicted to come up at 480 and did not. It settles the question the other way: a cold boot on `11:00.4` enumerates at full speed *cleanly* — no `-110`, no failed HID probe, no retry, nothing in the log at all. There is no failure to blame, so the fallback is not a failure. **This controller's ports negotiate full speed with this dongle; `0f:00.0` negotiates high speed.**

Two separate things were being conflated, and the error storms hid it:

- **The `-110`/`-71` storms are the hot-plug**, and they are what produce a *retry* at full speed. Powering the headset off before re-seating avoids them — with it off the failures are `-22`/`-71` and finish inside a second, with it on they are `-110` timeouts that run back to back for ~90 s and freeze whatever else shares the controller.
- **The steady-state 12 Mbps on `5-2` is the port**, and is silent and error-free.

Since full speed does not starve this stream (see above), the live trade-off is:

- **`11:00.4` at 12 Mbps** — a wedged dongle cannot freeze the input devices. **Currently chosen.**
- **`0f:00.0` at 480 Mbps** — back on the same controller as the Steam Controller, Logitech receiver and ITE device, where a 90 s stall takes them all down.

Isolation is worth more than a link speed that is not a bottleneck, so it stays on `11:00.4`. Revisit only if full speed turns out to cost something measurable — its 1 ms frames rather than 125 µs microframes mean slightly coarser isochronous scheduling, which is a latency argument, not a dropout one.

## Recovery takes about three minutes, and re-plugging restarts the clock

2026-08-22. The dongle was moved to a front port and appeared dead — no LED, nothing in `lsusb`, no card in `/proc/asound/cards`. It was not dead. It was mid-recovery, and every re-plug restarted that recovery from zero.

```
16:13:30  usb 1-3: USB disconnect, device number 3           <- pulled from the rear port
16:16:18  usb 1-4: new full-speed USB device number 6        <- 0e8d:0003, the firmware loader
16:16:18  usb 1-4: USB disconnect, device number 6
16:16:19  usb 1-4: new high-speed USB device number 7        <- 10f5:2242, attempt 1
16:17:36  usbhid 1-4:1.3: can't add hid device: -71
16:17:36  usb 1-4: USB disconnect, device number 7
16:17:37  usb 1-4: new high-speed USB device number 8        <- attempt 2
16:19:04  usbhid 1-4:1.3: can't add hid device: -110
16:19:04  usb 1-4: USB disconnect, device number 8
16:19:05  usb 1-4: new full-speed USB device number 9        <- attempt 3, works
```

It enumerates twice on arrival: first as `0e8d:0003` (a MediaTek loader), which drops off within a second and comes back as `10f5:2242`. That pair is normal and is not a failure.

What follows is: two full high-speed attempts failed before the full-speed retry stuck. **2 min 46 s from first plug to working audio**, at roughly 90 s per attempt — the `-110` storm described above.

Nothing in that window looks like progress. The LED stays dark *between* attempts, not just during them, so the natural reading is "the dongle is dead" and the natural response is to re-plug — which discards the attempt in flight and starts another 90 s. Three re-plugs is nine minutes of a device that was going to fix itself in three.

**After plugging this dongle in, wait three minutes before touching it.** Watch instead of re-plugging:

```
journalctl -k -f | rg 'usb 1-|usb 5-'
```

Powering the headset off before re-seating still avoids the storms entirely and remains the better move. But once it is already plugged in with the headset on, waiting is the fix.

### The mixer looks broken while it is recovering

Worth recording because it reinforces the wrong conclusion. During a failed attempt the driver cannot read the volume range, and falls back to a single step:

```
usb 1-4: 2:0: cannot get min/max values for control 2 (id 2)
usb 1-4: Warning! Unlikely small volume range (=1), linear volume or custom curve?
usb 1-4: [2] FU [PCM Playback Volume] ch = 1, val = 0/1/1
```

A healthy enumeration reports `Limits: Playback 0 - 74`. So `amixer -c <n>` showing a one-step range means the device is still mid-recovery — it does not mean the headset's volume control is broken, and it resolves itself when the successful attempt lands.

## The front ports are on the wrong controller

The front-panel ports enumerate as `1-3` and `1-4` on `0f:00.0` — the same controller as the Steam Controller Puck and the ITE device, and precisely the controller [It takes the controller with it](#it-takes-the-controller-with-it) moved the dongle *off*. Convenience is on the front, isolation is on the rear. Keep it on `11:00.4`, which enumerates as `5-2`.

## Untested: quirks that might shorten the recovery

Not applied, and recorded here so they are not re-derived from scratch. All of them target the `-110` control-transfer timeouts, which are what makes each failed attempt cost 90 s rather than a second.

Both parameters are writable at runtime as root, so each can be tried without a reboot — write, then re-seat the dongle:

| Knob | Value | What it does |
|---|---|---|
| `/sys/module/usbcore/parameters/quirks` | `10f5:2242:gn` | `g` = `USB_QUIRK_DELAY_INIT`, `n` = `USB_QUIRK_DELAY_CTRL_MSG`. Paces enumeration for devices that cannot answer control requests promptly. |
| `/sys/module/snd_usb_audio/parameters/quirk_flags` | `0x10f5:0x2242:0x4100` | bit 8 `CTL_MSG_DELAY` (20 ms between control messages) + bit 14 `IGNORE_CTL_ERROR` (do not fail the mixer on a timed-out control request). |

Letter and bit assignments verified against [`drivers/usb/core/quirks.c`](https://github.com/torvalds/linux/blob/master/drivers/usb/core/quirks.c) and [`sound/usb/usbaudio.h`](https://github.com/torvalds/linux/blob/master/sound/usb/usbaudio.h) rather than from memory — several widely-copied blog values are wrong.

Caveats before spending time on these:

- `usbcore` is **built in** on this kernel, not a module, so `/etc/modprobe.d` will not work for it. A permanent setting needs `usbcore.quirks=` on the kernel cmdline via a new `/etc/default/grub.d/*.cfg` — never by editing Valve's `grub-steamos`.
- `snd_usb_audio` *is* a module, so it can use `/etc/modprobe.d` — which is **not** on the atomic-update allowlist and needs both a keep entry and a boot self-heal.
- The `-110` timeouts come from the dongle not answering while its 2.4 GHz link is down. Delays and ignored errors may only make the driver more patient about a wait that still has to happen. Measure the recovery time before and after; do not assume.
- Powering the headset off before re-seating already avoids the storms, at zero risk and zero config. Try these only if that is not good enough.

## Re-seating resets the default sink

WirePlumber picks a new default when the headset disappears and does not switch back when it returns — after a re-seat the default sink was `HDA ATI HDMI`, so game audio goes to the TV rather than the headset, silently. Check `wpctl status` after any re-seat, and `wpctl set-default <id>` to put it back.
