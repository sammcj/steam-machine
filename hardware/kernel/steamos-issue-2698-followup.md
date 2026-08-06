# Follow-up for ValveSoftware/SteamOS#2698

## Making it work with a recent kernel

I've got this working on a hand-built kernel, **below are the specific on how I did this in case they're useful.**

_Note: the below content is heavily written by Claude Opus 5, so it's a bit verbose sorry._

FRL for DCN 4.0.1 landed in the 7.2 merge window. SteamOS 3.8.24 ships `linux-neptune-616-drm-exec` 6.16.12, so the code isn't present.

`amdgpu.ko` from `linux-neptune-616-drm-exec` 6.16.12, `linux-neptune-618-drm-exec` 6.18.33 and `linux-neptune-618` 6.18.38 all have a byte-identical FRL symbol set, and none contain `dcn401_hpo_frl_stream_encoder`, `link_hdmi_frl` or `link_hwss_hpo_frl`. The `*frl*` symbols present in all three belong to the DP-to-HDMI PCON path, which is why a DP→HDMI 2.1 converter works today and the native port doesn't.

On mainline `v7.2-rc6` with `amdgpu.dcfeaturemask=0x402`, RX 9070 XT (Navi 48, `1002:7550`) → LG C9 over the native HDMI port:

```
3840x2160 @ 120.00 Hz, RGB 4:4:4, 12 bpc
pixel clock 1188.00 MHz
DSC off (CLOCK_EN 0)
single pipe (ODM Segments 0)
underflow 0
```

DTN log, confirming it's the native FRL path rather than PCON:

```
HPO:   OTG Inst     Link   Pixel Format   Depth   ODM Segments   Lanes   Borrow   h_active   h_blank
[0]:          0   Training        4:4:4      12              0       4   ACTIVE       3840       560
```

`dmesg` also shows `hdmi_frl_status_polling_workque`. HDR works - connector `Colorspace` goes `0` → `9` (`BT2020_RGB`) in-game, so gamescope's colour offload is unaffected.

If a backport is on the table, the merged commits are these, all in `v7.2-rc6` (`075b74841bd0`):

```
c3778921bf0d  Disable FRL and add module param to enable it
443290d70b01  Add AV mute wait frames to dce110_set_avmute
c216b39fbbc4  Increase HDMI AV mute wait from 2 to 3 frames
fed376e1f2e3  Fix kdoc parameter names for DSC padding helper
ee911514a9f8  Rename hdmi_frl_borrow_mode
5726af470517  Widen FRL debug knobs to unsigned int
1e13b7eb67f9  Widen dc_hdmi_frl_flags.force_frl_rate to unsigned int
```

Plus the 14-patch series and the ~9 register-header commits split out of it before merge - a `git am` of the mailing-list v3 mbox won't compile without those, so cherry-picking merged SHAs is the easier route. The two AV-mute commits are `Cc: stable` and fix garbled display after link re-establishment.

Worth noting: `c3778921bf0d` leaves FRL off by default behind `DC_FRL_MASK` (bit 10), so carrying the code doesn't change behaviour for existing users or Decks unless they set the mask.

Two things that cost me time, in case they're worth a doc note:

- The parameter is `amdgpu.dcfeaturemask`, not `dc_feature_mask` - the latter is the C variable, and it's what every guide on the web quotes.
- It replaces the mask rather than OR-ing into it, so the widely-quoted `0x400` clears the default `DC_MULTI_MON_PP_MCLK_SWITCH_MASK` (`0x2`). `0x402` is correct.

One thing that still doesn't work, not a blocker for the above:

- **CEC.** amdgpu registers no CEC adapter for its own HDMI ports, so there's no `/dev/cec*` on any kernel. `hdmi_cec_state` reporting `1` is the sink's DDC-advertised capability. Unrelated to FRL.

One SteamOS-side thing, relevant to anyone testing an alternate kernel: `GRUB_TIMEOUT` in `/etc/default/grub*` has no effect - the generated `grub.cfg`'s steamenv header hardcodes `timeout=0`, so no menu appears and an alternate entry is unreachable. `/efi/EFI/steamos/custom.cfg`, sourced later by `41_custom`, is the override that works.

Setup, for reproduction:

- SteamOS 3.8.24 (`BUILD_ID=20260716.2`), stock kernel 6.16.12
- Navi 48 `1002:7550`, Ryzen 7 9800X3D, Gigabyte B850M
- LG C9 (HDMI 2.1, 4K120, 40-120 VRR, HDR10)
- Kernel: mainline `v7.2-rc6` plus `-DAMD_PRIVATE_COLOR` in `drivers/gpu/drm/amd/display/amdgpu_dm/Makefile` (that's the upstream equivalent of `CONFIG_DRM_AMD_COLOR_STEAMDECK`, needed to keep gamescope's per-plane colour offload on a non-Valve kernel)

Method, config, raw debugfs captures and the install scripts: <https://github.com/sammcj/steam-machine/tree/main/hardware/kernel>

Happy to run tests on this hardware if that's useful.

<details>
<summary>Working output proof</summary>

```
======================================================================
 HDMI 2.1 FRL @ 4K120 on Radeon RX 9070 XT (RDNA4 / DCN 4.0.1)
 Linux 7.2-rc6 on SteamOS 3.8 -- native HDMI port, no DP converter
 Captured: 2026-08-06 06:21:55 UTC
======================================================================

--- 1. KERNEL -------------------------------------------------------
Linux steammachine 7.2.0-rc6-frlprobe #1 SMP PREEMPT_DYNAMIC Thu Aug  6 05:17:52 UTC 2026 x86_64 GNU/Linux

amdgpu.dcfeaturemask (DC_FRL_MASK 0x400 | DC_MULTI_MON_PP_MCLK_SWITCH 0x2):
  cmdline: amdgpu.dcfeaturemask=0x402
  live   : 1026  (decimal; 0x402)

--- 2. GPU / DISPLAY CORE -------------------------------------------
[    7.674815] amdgpu 0000:03:00.0: [drm] Display Core v3.2.384 initialized on DCN 4.0.1
[    8.444515] amdgpu 0000:11:00.0: [drm] Display Core v3.2.384 initialized on DCN 3.1.5
03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 48 [Radeon RX 9070/9070 XT/9070 GRE] [1002:7550] (rev c0)
11:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Granite Ridge [Radeon Graphics] [1002:13c0] (rev cb)

--- 3. NATIVE FRL PATH IS ACTIVE ------------------------------------
Workqueue created only by the 7.2 native-FRL code:
[    8.010038] workqueue: name exceeds WQ_NAME_LEN. Truncating to: hdmi_frl_status_polling_workque

--- 4. CONNECTOR ----------------------------------------------------
Connected connectors:
  card0-HDMI-A-1: connected
  (DP-* absent: the DP-to-HDMI 2.1 converter has been removed)

--- 5. TIMING -- proves FRL, not TMDS --------------------------------
OTG:  v_bs  v_be  v_ss  v_se  vpol  vmax  vmin  vmax_sel  vmin_sel  h_bs  h_be  h_ss  h_se  hpol  htot  vtot  underflow blank_en
[0]:  2242    82     0    10     0     0     0         0         0  4224   384     0    88     0  4399  2249          0        0


  htotal x vtotal x refresh = 4400 x 2250 x 120 Hz  (DTN prints the raw OTG
  registers, which store total-1; dcn10_optc.c programs OTG_H_TOTAL = h_total-1)
  => pixel clock 1188.00 MHz
  HDMI 2.0 TMDS hard ceiling  : 600.00 MHz
  => 1188.00 MHz is 1.98x the TMDS limit; only FRL can carry it.

--- 6. LINK / STREAM ENCODER ----------------------------------------
HPO:   OTG Inst     Link   Pixel Format   Depth   ODM Segments   Lanes   Borrow   h_active   h_blank
[0]:          0   Training        4:4:4      12              0       4   ACTIVE       3840       560

  Lanes 4, pixel format 4:4:4, depth 12 bpc, ODM Segments 0 (single pipe).

Max output bpc reported by the driver:
  Maximum: 12

--- 7. UNCOMPRESSED (no DSC needed) ---------------------------------
DSC: CLOCK_EN  SLICE_WIDTH  Bytes_pp
[0]: 0         0            0         

[1]: 0         0            0         
  CLOCK_EN 0 => DSC disabled. 4K120 4:4:4 12-bit carried uncompressed.

--- 8. NO UNDERFLOW -------------------------------------------------
HUBP:  format  addr_hi  width  height  rot  mir  sw_mode  dcc_en  blank_en  clock_en  ttu_dis  underflow   min_ttu_vblank       qos_low_wm      qos_high_wm
[ 0]:      8h      83h   1920    1080   0h   0h       3h       1         0         1        0         0h           63.760            0.000           14.800
[ 1]:      8h      83h   3840    2160   0h   0h       3h       1         0         1        0         0h           63.760            0.000           14.800
[ 2]:      8h      83h   3840    2160   0h   0h       3h       1         0         1        0         0h           63.760            0.000           14.800
[ 3]:      0h       0h      0       0   0h   0h       0h       0         0         0        0         0h            0.000            0.000            0.000
  underflow column reads 0h on every active pipe.

--- 9. SINK (LG C9) HDR CAPABILITY ----------------------------------
  HDR Static Metadata Data Block:
    Electro optical transfer functions:
      Traditional gamma - SDR luminance range
      SMPTE ST2084
      Hybrid Log-Gamma
    Supported static metadata descriptors:
      Static metadata type 1
  YCbCr 4:2:0 Capability Map Data Block:
    VIC  97:  3840x2160   60.000000 Hz  16:9    135.000 kHz    594.000000 MHz

--- 10. KNOWN LIMITATIONS -------------------------------------------
VRR: not available at the time of this capture -- stock 7.2 ships FRL
     without HDMI VRR (upstream commit c3778921bf0d gates FRL off by
     default for exactly this reason).
     Min: 0
     Max: 0
     Solved later the same day by applying AMD's unmerged 4-patch series;
     the same debugfs entry then reads Min: 40 / Max: 120 and vrr_capable
     is 1. Full capture in ADDENDUM 2 at the end of this file.
CEC: no adapter registered. The cec module is loaded but amdgpu does not
     expose a CEC adapter on its native HDMI ports:
     cec                    98304  2 drm_display_helper,amdgpu
     /dev/cec*: none

======================================================================
 SUMMARY: 3840x2160 @ 120 Hz, RGB 4:4:4, 12 bpc, uncompressed,
 single pipe, zero underflow, over the native HDMI port at a
 1188.00 MHz pixel clock -- 1.98x the HDMI 2.0 TMDS ceiling.
======================================================================

======================================================================
 ADDENDUM -- HDR CONFIRMED ACTIVE (second capture, HDR game running)
 Captured: 2026-08-06 06:27:32 UTC
======================================================================

--- 11. HDR OUTPUT ACTIVE -------------------------------------------
Connector HDMI-A-1 'Colorspace' property = 9
  DRM_MODE_COLORIMETRY_BT2020_RGB == 9 (include/drm/drm_connector.h)

  This is the exact test gamescope uses to report HDR as active
  (src/Backends/DRMBackend.cpp, CDRMConnector::IsHDRActive):
      return GetProperties().Colorspace->GetCurrentValue()
             == DRM_MODE_COLORIMETRY_BT2020_RGB;

  Earlier capture on the SDR desktop read Colorspace = 0 (Default).
  It is now 9, i.e. the output switched into BT.2020 RGB.

Connector 'content type' = 4 (Game) -- drives the HDMI ALLM signal.
Connector 'max bpc'      = 16

--- 12. SCANOUT FORMAT CHANGED FOR HDR ------------------------------
HUBP surface format on the composited plane changed 8h -> 18h between
the SDR and HDR captures (8h = 32-bit ARGB8888; 18h = a 64-bit
half-float surface, the format gamescope composites HDR into).
HUBP:  format  addr_hi  width  height  rot  mir  sw_mode  dcc_en  blank_en  clock_en  ttu_dis  underflow   min_ttu_vblank       qos_low_wm      qos_high_wm
[ 0]:      8h      83h   1920    1080   0h   0h       3h       1         0         1        0         0h           61.880            0.000           14.800
[ 1]:      8h      83h   3840    2160   0h   0h       3h       1         0         1        0         0h           61.880            0.000           14.800
[ 2]:     18h      82h   3840    2160   0h   0h       3h       1         0         1        0         0h           61.880            0.000           14.800
[ 3]:      0h       0h      0       0   0h   0h       0h       0         0         0        0         0h            0.000            0.000            0.000

--- 13. LINK UNCHANGED UNDER HDR LOAD -------------------------------
HPO:   OTG Inst     Link   Pixel Format   Depth   ODM Segments   Lanes   Borrow   h_active   h_blank
[0]:          0   Training        4:4:4      12              0       4   ACTIVE       3840       560

  Still 4 lanes, 4:4:4, 12 bpc, single pipe, underflow 0h -- while
  running an HDR game at 4K120.

Sink confirmation: the LG C9's own OSD reports HDR, and SteamOS
reports HDR enabled.

======================================================================
 FINAL: 3840x2160 @ 120 Hz, RGB 4:4:4, 12 bpc, uncompressed, HDR10
 (BT.2020 RGB), zero underflow, over the native HDMI port on a
 Radeon RX 9070 XT -- using HDMI 2.1 FRL merged in Linux 7.2.
======================================================================

================================================================
 ADDENDUM 2 -- HDMI VRR + ALLM over FRL, 2026-08-06
 Kernel: 7.2.0-rc6-frlprobe + Fangzhi Zuo's 4-patch series
         (amd-gfx, 30 Jul 2026, Reviewed-by Harry Wentland)
================================================================

--- 1. Sink capability, from the EDID's HDMI Forum VSDB -------------

  Note: this EDID has NO AMD VSDB / FreeSync block at all. Before the
  series, amdgpu derived FreeSync capability only from the AMD block,
  so this TV could never report VRR -- on FRL or on the converter.

--- 2. vrr_range (debugfs) ------------------------------------------
Min: 40
Max: 120
Was 'Min: 0  Max: 0' on every previous kernel.

--- 3. vrr_capable DRM property on the connected HDMI-A-1 -----------
160 vrr_capable:
  flags: immutable range
  values: 0 1
  value: 1
Was 'value: 0'. This is the property userspace gates VRR on.

--- 4. content type = Game (drives ALLM) ----------------------------
158 content type:
  flags: enum
  enums: No Data=0 Graphics=1 Photo=2 Cinema=3 Game=4
  value: 4

--- 5. Active mode, straight from the kernel ------------------------
#0 3840x2160 120.00 3840 4016 4104 4400 2160 2168 2178 2250 1188000 flags: phsync, pvsync; type: driver
1188000 kHz = 1188.00 MHz -- 1.98x the 600 MHz TMDS ceiling.

--- 6. OTG dynamic vtotal now programmed ----------------------------
OTG:  v_bs  v_be  v_ss  v_se  vpol  vmax  vmin  vmax_sel  vmin_sel  h_bs  h_be  h_ss  h_se  hpol  htot  vtot  underflow blank_en
[0]:  2242    82     0    10     0  4500  4500         1         1  4224   384     0    88     0  4399  2249          0        0
vmax/vmin 4500 with vmax_sel/vmin_sel = 1. Both selectors read 0
before the series -- DRR was never armed.

--- 7. Link unchanged: still native FRL, uncompressed, 12 bpc -------
HPO:   OTG Inst     Link   Pixel Format   Depth   ODM Segments   Lanes   Borrow   h_active   h_blank
[0]:          0   Training        4:4:4      12              0       4   ACTIVE       3840       560

DSC: CLOCK_EN  SLICE_WIDTH  Bytes_pp
[0]: 0         0            0         
```

</details>

---


## Update: VRR and ALLM now work too

Update: HDMI VRR and ALLM now work on this setup too, so the "known limitations" in the description are stale. Same kernel, plus Fangzhi Zuo's four patches from 30 July (`20260730171754.704049-1-jerry.zuo@amd.com`), all Reviewed-by Harry Wentland on 31 July, still unmerged.

```
vrr_range      Min: 40  Max: 120     (was Min: 0  Max: 0)
vrr_capable    1                     (was 0)
content type   4 (Game)              -> HF-VSIF with ALLM_Mode=1
mode           3840x2160 @ 120.00, RGB 4:4:4, 12 bpc, DSC off, underflow 0
```

The link is unchanged underneath: still native FRL, 4 lanes, uncompressed, single pipe.

The hardware side confirms it rather than just the property flipping - the DTN log's OTG row now reads `vmax 4500 vmin 4500` with `vmax_sel`/`vmin_sel` both `1`. Both selectors were `0` on every earlier kernel, so dynamic vtotal was reachable on the FRL path the whole time and simply never armed.

## The part that seems worth your attention

**This TV has no AMD VSDB in its EDID at all** - no FreeSync block. Before that series, `amdgpu_dm_update_freesync_caps()` derived HDMI FreeSync capability solely from the AMD block, so an LG C9 could never report VRR on any path, converter included. What it does advertise, in the HDMI Forum VSDB, is:

```
Supports Auto Low-Latency Mode
VRRmin: 40 Hz
VRRmax: 120 Hz
```

Patch 3/4 (`Add HDMI 2.1 VRR support from HF-VSDB`) is the fallback that reads those. Patch 1/4, which extends the *AMD* VSDB path to FRL, does nothing at all on this display.

That generalises past my hardware: HDMI 2.1 TVs advertise VRR through the HF-VSDB, not through AMD's vendor block. For a living-room device attached to a TV rather than a FreeSync monitor, 3/4 is the patch that matters.

It also bears on the FRL default. `c3778921bf0d` disables FRL because shipping FRL without VRR would be a regression. Taken **together**, the FRL series and these four patches don't have that problem - on this hardware you get 4K120 *and* 40-120 VRR *and* ALLM. If a neptune backport included both, the reason to keep the mask off largely goes away.

ALLM is a real console-behaviour win too: content type Game now puts the TV into its low-latency mode by itself, which is the sort of thing that should just happen on a Steam Machine.

## Notes for whoever does the backport

- The series is against `amd-staging-drm-next`, which has split `amdgpu_dm_connector.c` out of `amdgpu_dm.c`. Mainline hasn't, so on 7.2 those hunks go into `amdgpu_dm.c`. Same surrounding code; it's relocation, not a rewrite. `amdgpu_dm_get_highest_refresh_rate_mode()` is plain `get_highest_refresh_rate_mode()` there, and the `STATIC_IFN_KUNIT`/`EXPORT_IF_KUNIT` wrappers don't exist.
- Patch 2/4 is a **DRM core** change (`drm_edid.c`, `drm_connector.h`). Harry noted it needs dri-devel as well as amd-gfx.
- Patch 4/4 has an outstanding review comment - read the ALLM bit from `aconn->base.display_info.hdmi.allm` instead of adding a field to `dc_edid_caps`, which drops the `dc_types.h` and `amdgpu_dm_helpers.c` hunks. I applied it as posted; a v2 would be better.
- Not in `amd-staging-drm-next` as of today, but note that branch's tip is `d8ab7636160e` dated 29 July - one day *before* the series was posted - so its absence there doesn't mean much.
- Worth grabbing at the same time: `drm/amd/display: restore FRL cap on non-destructive HDMI link verify` (also Zuo, August). Without it an FRL link can drop back to TMDS across a hotplug.

## What I haven't verified

Uptime on this is hours, not weeks. I haven't measured actual refresh behaviour inside a game with a capture device - what I can show is the driver state and the OTG registers, not a frame-time trace. ALLM is confirmed as far as "we send it and the sink advertises support".

Patches as ported, plus the full debugfs captures: <https://github.com/sammcj/steam-machine/tree/main/hardware/kernel>

Happy to test a candidate neptune build on this hardware - RDNA4 plus a 2019 HDMI 2.1 TV is probably a useful combination to have on the other end of a patch. If a verbose log would help, the series carries `drm_dbg_driver()` lines (`VRR: enter ...`, `VRR: HF-VSDB fallback ...`, `ALLM: set mode ...`) that show the whole decision path under `drm.debug=0x2` - say the word and I'll post one.
