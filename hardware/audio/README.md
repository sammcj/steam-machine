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

`install.sh --status` reports the current link speed for this reason. If it says anything other than 480, re-seat the dongle **with the headset powered off**, so the link is not being negotiated while the kernel is trying to enumerate.

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

## Re-seating resets the default sink

WirePlumber picks a new default when the headset disappears and does not switch back when it returns — after a re-seat the default sink was `HDA ATI HDMI`, so game audio goes to the TV rather than the headset, silently. Check `wpctl status` after any re-seat, and `wpctl set-default <id>` to put it back.
