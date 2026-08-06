# Follow-up for ValveSoftware/SteamOS#2698

Draft comment for <https://github.com/ValveSoftware/SteamOS/issues/2698> - "SteamOS doesn't support 4k 120hz via HDMI (AMD Radeon RX 9070 XT)".

Paste the section between the rules as a comment.

---

Follow-up: I've got this working on a hand-built kernel, so here are the specifics in case they're useful.

FRL for DCN 4.0.1 landed in the 7.2 merge window. SteamOS 3.8.24 ships `linux-neptune-616-drm-exec` 6.16.12, so the code isn't present. I checked rather than assumed - `amdgpu.ko` from `linux-neptune-616-drm-exec` 6.16.12, `linux-neptune-618-drm-exec` 6.18.33 and `linux-neptune-618` 6.18.38 all have a byte-identical FRL symbol set, and none contain `dcn401_hpo_frl_stream_encoder`, `link_hdmi_frl` or `link_hwss_hpo_frl`. The `*frl*` symbols present in all three belong to the DP-to-HDMI PCON path, which is why a DP→HDMI 2.1 converter works today and the native port doesn't.

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

Two things that still don't work, neither of them blockers for the above:

- **HDMI VRR.** 7.2 shipped FRL without it, which is the stated reason it's default-off. The ALLM + HDMI VRR series isn't in `amd-staging-drm-next` either as of today (`d8ab7636160e`) - `allm_mode`, `hdmi_vrr_desktop_mode` and `freesync_pcon_allow_all` are absent from that tree while present in neptune 6.18.
- **CEC.** amdgpu registers no CEC adapter for its own HDMI ports, so there's no `/dev/cec*` on any kernel. `hdmi_cec_state` reporting `1` is the sink's DDC-advertised capability. Unrelated to FRL.

One SteamOS-side thing, relevant to anyone testing an alternate kernel: `GRUB_TIMEOUT` in `/etc/default/grub*` has no effect - the generated `grub.cfg`'s steamenv header hardcodes `timeout=0`, so no menu appears and an alternate entry is unreachable. `/efi/EFI/steamos/custom.cfg`, sourced later by `41_custom`, is the override that works.

Setup, for reproduction:

- SteamOS 3.8.24 (`BUILD_ID=20260716.2`), stock kernel 6.16.12
- Navi 48 `1002:7550`, Ryzen 7 9800X3D, Gigabyte B850M
- LG C9 (HDMI 2.1, 4K120, 40-120 VRR, HDR10)
- Kernel: mainline `v7.2-rc6` plus `-DAMD_PRIVATE_COLOR` in `drivers/gpu/drm/amd/display/amdgpu_dm/Makefile` (that's the upstream equivalent of `CONFIG_DRM_AMD_COLOR_STEAMDECK`, needed to keep gamescope's per-plane colour offload on a non-Valve kernel)

Method, config, raw debugfs captures and the install scripts: <https://github.com/sammcj/steam-machine/tree/main/hardware/kernel>

Happy to run tests on this hardware if that's useful.

---

## Notes before posting

- Check the repo URL resolves and that `frl-4k120-evidence.txt` is pushed before linking it.
- No serials, account IDs, addresses or private hostnames appear above - keep it that way if you edit it.
- If they ask for a full `dmesg`, capture it on the FRL kernel with `drm.debug=0x1e` and attach as a file rather than pasting inline.
