# Controllers

Notes on game controllers on this machine. Nothing is installed by this directory — there is no `install.sh`, because the one issue documented here has no local fix.

- [Steam Controller (2026) is detected as a Steam Deck](#steam-controller-2026-is-detected-as-a-steam-deck)
  - [Root cause](#root-cause)
  - [The controlled comparison](#the-controlled-comparison)
  - [What was ruled out](#what-was-ruled-out)
  - [Why it cannot be fixed locally](#why-it-cannot-be-fixed-locally)
  - [Flatpak Steam as a diagnostic](#flatpak-steam-as-a-diagnostic)
- [Kernel `hid-steam` has no IDs for the 2026 controller](#kernel-hid-steam-has-no-ids-for-the-2026-controller)

## Steam Controller (2026) is detected as a Steam Deck

Diagnosed 2026-08-05. The controller pairs and works, but Steam identifies it as a **Steam Deck** — Deck name, Deck glyphs, Deck configuration templates. The same controller on a MacBook Pro running an up-to-date Steam is identified correctly.

The device enumerates correctly at the USB level. `lsusb`:

```
Bus 001 Device 019: ID 28de:1304 Valve Software Steam Controller Puck
```

Wired, the controller itself is `28de:1302`; over the wireless puck it is `28de:1304`, which exposes seven interfaces. Steam reads the descriptors correctly — `~/.steam/steam/logs/controller.txt` shows `Manufacturer: Valve Software`, `Product: Steam Controller Puck`, and the controller's own firmware and board revision — so this is not a detection or permissions failure. It is a classification failure that happens after the device is read.

### Root cause

**The `steamdeck_*` Steam client branch that SteamOS pins itself to has essentially no support for the 2026 controller.** Its codename is **Triton**, following `gordon` (the 2015 Steam Controller) and `neptune` (the Deck).

Comparing the SteamOS-pinned client against the generic client, both installed on this machine at the same time:

| | `steamdeck_publicbeta` | generic client |
| --- | --- | --- |
| `steamclient.so` strings matching `Triton` | **1** | **164** |
| `steamui` controller types | `gordon`, `neptune`, `unknown` | `gordon`, `neptune`, **`triton`**, `unknown` |

The generic client carries the whole feature set — `CSteamInputService_GetTritonPairingInfo`, `TritonBond_t`, `CTritonQosStatus`, `CJobTritonBase`, `CSteamInputService_ShouldTritonPairInOobe`. The SteamOS branch contains exactly one Triton string, `CSteamControllerTritonPacketAbstraction`, and nothing else. The port was only ever partially landed.

In `steamui`, the generic client's controller-type table has a dedicated Triton entry:

```js
[s.AE]:"controller_steamcontroller_neptune",[s.VD]:"controller_steamcontroller_triton",
```

The SteamOS build's table has no such entry and stops at Neptune:

```js
2:"controller_steamcontroller_gordon",3:"controller_steamcontroller_unknown",4:"controller_steamcontroller_neptune",
```

With nothing to match, the controller falls through to the `default:` arm of the type-resolution switch — which is grouped with `case 4`, and `case 4` is Neptune:

```js
function h(e){switch(e){default:case 4:case 130:case 101:case 100:
  return l.k_EControllerTypeFlags_SteamControllerNeptune;
  case 3: return l.k_EControllerTypeFlags_SteamControllerV2;
  case 2: return l.k_EControllerTypeFlags_SteamController;
```

So on this branch **any** controller type Steam does not recognise renders as a Steam Deck. That is the whole mechanism.

Two visible consequences in the logs. Every configuration lookup resolves to a Deck template:

```
Loaded Config for Local Selection Path for App ID <id>, Controller 0: controller_base/desktop_neptune.vdf
Loaded Config for Last Resort Path for App ID 769, Controller 0: .../controller_base/basicui_neptune.vdf
Loaded Config for Last Resort Path for App ID <id>, Controller 0: .../controller_base/chord_neptune.vdf
```

And Steam routes the controller through the Deck hardware-registration path, with `BYieldingRegisterSteamController` / `BYieldingCompleteSteamControllerRegistration` firing repeatedly, never completing, and failing to create a per-controller config set:

```
ConfigSet - failed to find config set file on-disk: .../config/configset_<serial>.vdf
```

Note the type table does contain a `SteamControllerV2` case (`case 3`), but its asset string is `controller_steamcontroller_unknown`. Since the symptom is "Steam Deck" and not "Unknown", the controller is not reporting type 3 — it is genuinely hitting `default:`.

### The controlled comparison

Installing the generic client alongside via Flatpak and connecting the same controller **identified it correctly and immediately**. Same machine, same kernel, same udev rules, same controller, same puck — the client branch was the only variable. That is the empirical half of the diagnosis; the table above is the static half, and they agree.

### What was ruled out

Each of these was checked and is *not* the cause:

- **InputPlumber** — the service is `inactive (dead)` on this machine. Not involved. (SteamOS 3.8 ships it, and `90-steam-inputplumber.rules` only starts it when `USE_INPUTPLUMBER=1` is set on a DMI match, which does not happen here.)
- **udev permissions** — `60-steam-input.rules` matches `ATTRS{idVendor}=="28de"` by wildcard, so `1302` and `1304` are already covered, and `70-steam-jupiter-input.rules` tags *all* hidraw nodes `uaccess` regardless. Steam can open the device; it does.
- **The machine being mistaken for a Deck** — DMI reports `B850M FORCE WIFI6E V2` / Gigabyte. No Jupiter or Galileo, and no platform device claiming otherwise.
- **The `-steamdeck` flag, and the session type** — the obvious suspect, and not the cause. `/usr/bin/steam-jupiter` passes `-steamdeck` in *both* the gamescope and desktop sessions (confirmed in `bootstrap_log.txt`), and the misidentification happens in both. The fallback is in the type mapping, not the session.
- **A stale install** — the `steamui` package was downloaded 2026-08-02 with contents dated to 2026-07-22. Individual chunk mtimes read as old (one is 2025-10-03) but those are preserved from the archive, meaning that code path simply has not been rebuilt upstream. The client build is `1785347151` (2026-07-30) and `steamos-update check` reports no update available.

### Why it cannot be fixed locally

`/usr/bin/steam` is a symlink to `/usr/bin/steam-jupiter`, which pins the client branch before launching:

```bash
if [[ ! -e beta || $(cat beta) = *neptune || $(cat beta) = publicbeta || $(cat beta) = "steampal_stable_..." ]]; then
  echo -n "steamdeck_stable" > beta
fi
exec /usr/lib/steam/steam -steamdeck -pipewire "$@"
```

So editing `~/.local/share/Steam/package/beta` to point at the generic client does not survive — the wrapper rewrites it on the next launch. Calling `/usr/lib/steam/steam` directly would bypass the wrapper, but that mixes a generic client into the SteamOS-managed install and would churn the client up and down on every normal launch. Not worth it.

**Switching the client channel to Stable does not help either** — `steamdeck_stable` is *behind* `steamdeck_publicbeta`, which already lacks Triton. The only direction that could help is a newer channel, and the in-client menu offers no such option: it lists only "Steam Deck Stable" and "Steam Deck Beta".

Tried on 2026-08-05 and it made no difference. One caveat on that test: afterwards `package/beta` read `steamdeck_publicbeta` again, so the on-disk client was still the publicbeta build and the static check could not inspect an actual stable build. The observed behaviour matched the prediction, but the symbol count was never confirmed against a stable client.

#### "Beta" here is not newer than desktop "stable"

Worth being explicit, because it is counter-intuitive: `steamdeck_publicbeta` is the beta of the **Deck client lineage**, not a newer build of the desktop client. They are separate forks with separate version streams. Client version numbers are Unix timestamps, so they compare directly:

| | branch | build | date |
| --- | --- | --- | --- |
| Native | `steamdeck_publicbeta` | `1785347151` | 2026-07-30 03:45 |
| Flatpak | *no `beta` file* — generic **stable** | `1785799196` | 2026-08-04 09:19 |

The generic **stable** client is 5 days 5 hours **newer** than the SteamOS **beta** client. The gap itself is not the explanation, though — a five-day lag cannot account for a controller that shipped in May 2026. Triton support landed in the desktop lineage months ago and has simply never been merged into the Deck lineage, which is what the 1-versus-164 symbol count actually measures.

The fix has to come from Valve shipping Triton support to the `steamdeck_*` branch. Reported — see `steam-controller-2026-bug-report.md` in this directory for the filed text.

### Flatpak Steam as a diagnostic

`com.valvesoftware.Steam` from Flathub uses the generic client branch and is a clean A/B against the SteamOS client. It is safe to install alongside:

```bash
flatpak --user install flathub com.valvesoftware.Steam
```

Its sandbox cannot reach the native install. `persistent=.` gives it a private home at `~/.var/app/com.valvesoftware.Steam/`, and its `filesystems=` list has no `home`, no `~/.steam` and no `~/.local/share/Steam` — only `/mnt`, `/media`, `/run/media`, `/run/udev:ro` and a couple of read-only XDG directories. Flatpaks live outside the A/B rootfs images, so SteamOS updates are unaffected, and `--user` keeps everything in `/home/deck/.local/share/flatpak`. Verified after install: the native `package/beta` was still `steamdeck_publicbeta` with an unchanged mtime.

Worth remembering as a general technique — when Steam on this machine misbehaves with hardware that works elsewhere, diff the two clients before suspecting the kernel, udev or InputPlumber.

**It was removed again on 2026-08-05 once the test was done**, to avoid two Steam installs to trip over later. `--delete-data` is needed to clear the sandbox home as well as the app:

```bash
flatpak kill com.valvesoftware.Steam
flatpak --user uninstall --delete-data com.valvesoftware.Steam
flatpak --user uninstall --unused          # only org.freedesktop.Platform.codecs_extra.i386 was orphaned
```

Verified afterwards: no Valve flatpak listed, `~/.var/app/com.valvesoftware.Steam` gone, the user flatpak tree back to its 6.1 GB baseline, and the native install untouched (`package/beta` still `steamdeck_publicbeta`). Note that logging into the Flatpak client registers it as an authorised device on the Steam account — `--delete-data` clears the local tokens but the device entry stays server-side, so remove it under Steam → Settings → Security if you care.

## Kernel `hid-steam` has no IDs for the 2026 controller

A separate gap, and **not** the cause of the misidentification above.

`hid-steam` on the current neptune kernel (`6.16.12-...-neptune-616`) carries three IDs:

```
hid:b0003g*v000028DEp00001205    Steam Deck
hid:b0003g*v000028DEp00001142    2015 Steam Controller, dongle
hid:b0003g*v000028DEp00001102    2015 Steam Controller, wired
```

Neither `1302` nor `1304` is present, so all five puck HID interfaces fall through to `hid-generic`:

```
/sys/bus/hid/devices/0003:28DE:1304.0022  driver: hid-generic
```

Upstream mainline has not added the IDs either. Steam drives the controller over hidraw regardless, so this does not break anything on its own — but it means there is no in-kernel gamepad node, and it would need a kernel change rather than anything droppable in `/etc`. Nothing to do here until upstream moves.

## Related

- The **controller wake from sleep** item in the root README is about the DualSense over Bluetooth. There is an upstream report that the 2026 controller and its puck also fail to wake from suspend ([ublue-os/bazzite#4873](https://github.com/ublue-os/bazzite/issues/4873)) — **not tested on this machine**, noted only because it touches the same open item.
- [ValveSoftware/steam-for-linux#13185](https://github.com/valvesoftware/steam-for-linux/issues/13185) — open since May 2026, no Valve response. Reports the 2026 controller being routed through the Deck registration path on desktop Linux, with the trackpads failing to drive the system cursor. Possibly the same underlying cause seen from a different angle.
