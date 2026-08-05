# Bug report: Steam Controller (2026) detected as a Steam Deck on SteamOS

Draft prepared 2026-08-05, ready to file. Suggested target: **[ValveSoftware/SteamOS](https://github.com/ValveSoftware/SteamOS/issues)**, since the gap is specific to the SteamOS-pinned client branch. Worth cross-referencing from [ValveSoftware/steam-for-linux#13185](https://github.com/valvesoftware/steam-for-linux/issues/13185), which reports what may be the same underlying cause on desktop Linux.

Device serials and the Steam account ID have been redacted. Everything below is safe to post as-is.

---

**Title:** Steam Controller (2026) is detected as a Steam Deck — `steamdeck_*` client branch is missing Triton support present in the generic client

## Summary

On SteamOS, the Steam Controller (2026) is detected and rendered as a **Steam Deck** rather than as a Steam Controller — Deck name, Deck glyphs, Deck configuration templates. The same controller, on the same machine, is detected correctly by the generic Steam client.

The cause is that the `steamdeck_*` client branch SteamOS pins itself to has essentially no "Triton" support, while the generic client branch has it in full.

## Environment

- SteamOS 3.8.24 (`BUILD_ID 20260716.2`), beta branch
- Kernel `6.16.12-...-neptune-616`
- Steam client build `1785347151` (2026-07-30), branch `steamdeck_publicbeta`
- Hardware: DIY desktop running SteamOS (Gigabyte B850M FORCE WIFI6E V2, Ryzen 7 9800X3D, Radeon RX 9070 XT) — not a Steam Deck
- Steam Controller (2026): controller `28de:1302`, wireless puck `28de:1304`

## Steps to reproduce

1. On SteamOS, connect a Steam Controller (2026), either by cable or via the wireless puck.
2. Open Settings → Controller.
3. The controller is identified as a Steam Deck, with Deck glyphs and Deck configuration templates.

## Evidence

Comparing the SteamOS-pinned client against the generic client (Flathub `com.valvesoftware.Steam`), installed side by side on the same machine:

| | `steamdeck_publicbeta` | generic client |
| --- | --- | --- |
| `steamclient.so` strings matching `Triton` | **1** | **164** |
| `steamui` controller types | `gordon`, `neptune`, `unknown` | `gordon`, `neptune`, **`triton`**, `unknown` |

The generic client carries the full feature set — `CSteamInputService_GetTritonPairingInfo`, `TritonBond_t`, `CTritonQosStatus`, `CJobTritonBase`, `CSteamInputService_ShouldTritonPairInOobe`. The SteamOS branch contains exactly one Triton string, `CSteamControllerTritonPacketAbstraction`, and nothing else.

In `steamui`, the generic client's controller-type table includes a dedicated Triton entry:

```js
[s.AE]:"controller_steamcontroller_neptune",[s.VD]:"controller_steamcontroller_triton",
```

The SteamOS build's equivalent table has no such entry and stops at Neptune:

```js
2:"controller_steamcontroller_gordon",3:"controller_steamcontroller_unknown",4:"controller_steamcontroller_neptune",
```

With no Triton entry, the controller falls through to the `default:` arm of the type-resolution switch, which is grouped with `case 4` (Neptune):

```js
function h(e){switch(e){default:case 4:case 130:case 101:case 100:
  return l.k_EControllerTypeFlags_SteamControllerNeptune;
  case 3: return l.k_EControllerTypeFlags_SteamControllerV2;
  case 2: return l.k_EControllerTypeFlags_SteamController;
```

So on this branch any unrecognised controller type renders as a Steam Deck.

Consistent with that, `controller.txt` reads the USB descriptors correctly (`Manufacturer: Valve Software`, `Product: Steam Controller Puck`) but every configuration lookup then resolves to a Deck template:

```
Loaded Config for Local Selection Path for App ID <id>, Controller 0: controller_base/desktop_neptune.vdf
Loaded Config for Last Resort Path for App ID 769, Controller 0: .../controller_base/basicui_neptune.vdf
Loaded Config for Last Resort Path for App ID <id>, Controller 0: .../controller_base/chord_neptune.vdf
```

Steam also routes the controller through the Deck hardware-registration path, with `BYieldingRegisterSteamController` / `BYieldingCompleteSteamControllerRegistration` firing repeatedly, and fails to create a per-controller config set:

```
ConfigSet - failed to find config set file on-disk: .../config/configset_<serial>.vdf
```

## Controlled comparison

Installing the generic client alongside (`flatpak --user install flathub com.valvesoftware.Steam`) and connecting the same controller to the same machine, it is identified **correctly and immediately**. Same kernel, same udev rules, same controller, same puck — the client branch is the only variable.

Note that the generic client here is on **stable**, and is nonetheless newer than the SteamOS **beta**. Client versions are Unix timestamps and compare directly:

| | branch | build | date |
| --- | --- | --- | --- |
| SteamOS | `steamdeck_publicbeta` | `1785347151` | 2026-07-30 03:45 |
| Flathub | generic stable (no `beta` file) | `1785799196` | 2026-08-04 09:19 |

The five-day gap is not itself the explanation for a controller released in May 2026 — Triton support appears never to have been merged into the Deck client lineage at all.

## Ruled out

- **InputPlumber** — service is `inactive (dead)`; not involved.
- **udev permissions** — `60-steam-input.rules` matches VID `28de` by wildcard, and `70-steam-jupiter-input.rules` tags all hidraw `uaccess`.
- **Host misidentified as a Deck** — DMI reports the Gigabyte board; no Jupiter or Galileo.
- **The `-steamdeck` flag / session type** — `/usr/bin/steam-jupiter` passes `-steamdeck` in both the gamescope and desktop sessions, and the misidentification occurs in both. The fallback is in the type mapping, not the session.
- **Stale install** — the `steamui` package was current as of 2026-08-02; the relevant code path simply has no Triton entry on this branch.

## No user-side workaround

`/usr/bin/steam-jupiter` rewrites `~/.local/share/Steam/package/beta` back to `steamdeck_stable` whenever it is missing or set to `publicbeta` — that is, whenever it names either generic branch:

```bash
if [[ ! -e beta || $(cat beta) = *neptune || $(cat beta) = publicbeta || $(cat beta) = "steampal_stable_..." ]]; then
  echo -n "steamdeck_stable" > beta
fi
exec /usr/lib/steam/steam -steamdeck -pipewire "$@"
```

Both the Game Mode and desktop sessions go through this wrapper, so the branch cannot be held on a generic client. The in-client update-channel menu offers only "Steam Deck Stable" and "Steam Deck Beta", and Stable is behind Beta, so neither exposed option helps.

## Expected

The Steam Controller (2026) should be identified as a Steam Controller on SteamOS, with its own glyphs and configuration templates — ideally more promptly on SteamOS than anywhere else, given it is Valve's own hardware.
