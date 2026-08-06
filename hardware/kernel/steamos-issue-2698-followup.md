# Follow-up for ValveSoftware/SteamOS#2698

Draft comment for <https://github.com/ValveSoftware/SteamOS/issues/2698> - "SteamOS doesn't support 4k 120hz via HDMI (AMD Radeon RX 9070 XT)".

The FRL material is already in the issue description. This is the **VRR follow-up**: the description says VRR doesn't work, and that is now out of date.

Paste the section between the rules as a comment.

---

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

Happy to test a candidate neptune build on this hardware - RDNA4 plus a 2019 HDMI 2.1 TV is probably a useful combination to have on the other end of a patch.

---

## Notes before posting

- Check the repo URL resolves and that `patches/` and `frl-4k120-evidence.txt` are pushed before linking them.
- No serials, account IDs, addresses or private hostnames above - keep it that way if you edit it.
- If they ask for a full `dmesg`, capture it with `drm.debug=0x2` on the FRL kernel: the ported patches carry `drm_dbg_driver()` lines (`VRR: enter ...`, `VRR: HF-VSDB fallback ...`, `ALLM: set mode ...`) which are exactly what a maintainer would want to see. They are silent at the default debug level.
