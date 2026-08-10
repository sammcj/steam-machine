# Three ways to get 4K120 to the LG C9 — measured comparison

Every number here was read off this machine, not taken from a specification or a product page. Reproduce any of it with [`inspect-link.sh`](inspect-link.sh) (read-only, safe to run against a live session).

Dates matter, because two of the three were measured on different kernels: the converter rows below are **the same silicon on two different kernels**, which turns out to be the point.

## Summary

| | Native HDMI FRL | UGREEN 80397 | ULT-W11Q |
| --- | --- | --- | --- |
| Measured | 2026-08-06 | 2026-08-02 | 2026-08-10 |
| Kernel | mainline 7.2-rc6 (hand-built) | Valve 6.16 | mainline 7.2-rc6 (hand-built) |
| Connector | `HDMI-A-1` | `DP-1` | `DP-1` |
| 4K120 | yes | yes | yes |
| Compression | **none** | DSC 16 bpp (1.875:1) | DSC 12 bpp (2.5:1) |
| Depth | **12 bpc** | 10-bit RGB 4:4:4 | HDR + BT2020_RGB |
| Link | FRL | HBR3, 4 lanes | **HBR2**, 4 lanes |
| VRR | **40–120 Hz** | no | no |
| ALLM | yes | no | no |
| CEC | **impossible** | not measured | **yes** |
| Custom kernel needed | yes | no | no (but see VRR below) |

**Native FRL wins on picture and VRR. The converters win on CEC, which the native HDMI port can never do.**

## The two converters are the same chip

This is the finding that reframes everything. The ULT-W11Q is a different product in a different shape from the UGREEN 80397 cable, and it reports:

```
branch OUI        : 0x2B02F0
branch device ID  : CH7218
```

`0x2B02F0` is 2818800 in decimal — the exact `branch_dev_id` amdgpu printed for the UGREEN on 2026-08-02. Both are Chrontel CH7218. Any conclusion reached about one applies to the other, including the VRR result.

So a "better" DP→HDMI adapter is unlikely to be found by shopping: the interesting axis is the chip, not the brand, and CH7218 is what these products contain.

## Why the newer measurement compresses harder

Same chip, yet the UGREEN ran HBR3 at 16 bpp and the ULT-W11Q runs HBR2 at 12 bpp. The link report shows HBR3 was available and simply not used:

```
link_settings  Current: 4 0x14 0   Verified: 4 0x1e 16   Reported: 4 0x1e 16
```

`0x14` = 20 × 0.27 GHz = 5.4 Gbps/lane (HBR2). `0x1e` = 8.1 Gbps/lane (HBR3). The driver verified HBR3 and then trained down.

The arithmetic shows the two settings are a matched pair rather than two independent regressions. 4K120 with blanking is 4400 × 2250 × 120 = 1.188 Gpixel/s:

| Configuration | Payload | Fits in |
| --- | --- | --- |
| Uncompressed 30 bpp | 35.6 Gbps | nothing on DP 1.4 |
| DSC 16 bpp | 19.0 Gbps | HBR3 (25.9 Gbps effective) — **not** HBR2 |
| DSC 12 bpp | 14.3 Gbps | HBR2 (17.3 Gbps effective) |

(Effective rates are raw × 8/10 for 8b/10b.)

So choosing 12 bpp is what *permits* HBR2, and choosing HBR2 is what *requires* 12 bpp. It is one policy decision by the driver, not a hardware limit — the same chip demonstrably did HBR3/16 bpp on Valve 6.16. **Suspect the kernel or the DP cable, not the adapter.** Untested as of writing.

## VRR: the adapter is capable, amdgpu refuses

`dm_get_adaptive_sync_support_type()` in `drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm_helpers.c` requires **three** conditions before VRR passes through a DP→HDMI converter. Measured on the ULT-W11Q:

| Condition | Source | Result |
| --- | --- | --- |
| `ADAPTIVE_SYNC_SDP_SUPPORT` | DPCD 0x2214 bit 0 | `0x15` → **1, met** |
| `allow_invalid_MSA_timing_param` | DPCD 0x007 bit 6 | `0xc1` → **1, met** |
| `branch_dev_id` in whitelist | `dm_is_freesync_pcon_whitelist()` | **not met** |

The whitelist is five hardcoded OUIs and nothing else:

```c
case DP_BRANCH_DEVICE_ID_0060AD:
case DP_BRANCH_DEVICE_ID_00E04C:
case DP_BRANCH_DEVICE_ID_90CC24:
case DP_BRANCH_DEVICE_ID_001CF8:
case DP_BRANCH_DEVICE_ID_001FF2:
```

`0x2B02F0` is absent, so `vrr_capable` reads `0` and `vrr_range` reads `Min: 0 Max: 0`. The TV is not the obstacle — the converter passes the C9's real EDID through untouched, HF-VSDB and all, so `VRRmin: 40 Hz` / `VRRmax: 120 Hz` reaches the GPU and is discarded.

The product advertising "VRR and FreeSync" is not wrong about the silicon; it speaks to the first two conditions, and no product can advertise itself onto a driver allowlist.

### Whether patching the whitelist would work

Tempting — this machine builds its own kernels, so it is one line. The honest position is **plausible but with direct evidence against**:

- **Against:** on 2026-08-02 the Valve kernel's `freesync_pcon_allow_all=1` bypassed the whitelist for this same CH7218 and VRR still reported `Min: 0 Max: 0`, *and* it broke the picture. Recorded in [`README.md`](README.md).
- **For:** that test was on Valve 6.16, and nobody had measured DPCD 0x2214 at the time. Both preconditions are now confirmed set on 7.2-rc6, which is new information.

`freesync_pcon_allow_all` does **not exist on mainline 7.2-rc6** — absent from `drivers/gpu/drm/amd/` entirely. It is a downstream parameter, so the 2026-08-02 bypass is not even available on the current kernel; a source patch is the only route.

## CEC only exists on the converter path

amdgpu implements no HDMI CEC. On the native HDMI port there is no `/dev/cec0` at all, which is why the `steamos-cec-toolkit` was inert and got removed on 2026-08-08.

Through a DP converter, CEC arrives over the DP AUX tunnel (`drm_dp_cec`) and works fully:

```
Adapter Name       : DP-1        Physical Address : 2.0.0.0
CEC Version        : 2.0         Logical Address  : 4 (Playback Device 1)

System Information for device 0 (TV):
  Vendor ID        : 0x00e091 (LG)     Power Status : On
```

SteamOS's own `cecd` picks it up unaided — `rc0` (`rc-cec`) plus `cecd DP-1` input devices appear at boot, so the TV remote reaches the machine.

This is permanent, not a tuning problem: CEC is a property of the connector type, so it is available on the converter path and unavailable on the native HDMI path, whatever else is done.

## Verdict

**Native HDMI FRL is the better path for this machine.** Uncompressed 12 bpc and working 40–120 Hz VRR are worth more on a gaming box than CEC, and the converter's structural advantage — no custom kernel — largely evaporates once VRR is wanted, since the whitelist patch needs a custom kernel too.

Reasons to switch to the converter anyway, all legitimate:

- CEC matters more than VRR for how the room is actually used (TV remote, input switching).
- The custom kernel becomes too costly to maintain across SteamOS releases.
- DSC at 12 bpp is genuinely invisible to you in practice — it is a good codec, and this is a TV at couch distance.

**Both at once, if wanted:** keep video on native HDMI and leave a CH7218 converter on a spare DP port into an unused TV input purely as a CEC endpoint. `/dev/cec0` comes from the AUX tunnel and does not require the output to display anything; gamescope would need pinning to the HDMI output. Untested.
