# Follow-up for ValveSoftware/SteamOS#2698

Draft comment for <https://github.com/ValveSoftware/SteamOS/issues/2698> — "SteamOS doesn't support 4k 120hz via HDMI (AMD Radeon RX 9070 XT)".

The point of this follow-up is to move the issue from "doesn't work" to "here is the exact change, here is the measurement proving it works on this hardware, and here is why it costs you nothing to ship". Everything below was measured on the machine, not quoted from an article.

Paste the section between the rules as a comment.

---

## It works. Here is what it takes.

I've since built a kernel that does 4K 120 Hz over the native HDMI port on this exact hardware, so this is no longer a feature request — it's a backport request with a known-good result.

### What now runs

RX 9070 XT (Navi 48, `1002:7550`) → LG C9, native HDMI port, no DP→HDMI converter:

```
Mode        3840x2160 @ 120.00 Hz
Pixel clock 1187.20 MHz          (1.98x the 600 MHz HDMI 2.0 TMDS ceiling)
Format      RGB 4:4:4, 12 bpc
DSC         off (CLOCK_EN 0) -- uncompressed
Pipes       single (ODM Segments 0)
Underflow   0
HDR         active in-game (connector Colorspace = 9, BT2020_RGB)
```

The DTN log's HPO block, which is the thing that proves it's the *native* FRL path and not the PCON one:

```
HPO:   OTG Inst     Link   Pixel Format   Depth   ODM Segments   Lanes   Borrow   h_active   h_blank
[0]:          0   Training        4:4:4      12              0       4   ACTIVE       3840       560
```

`dmesg` also shows `hdmi_frl_status_polling_workque`, which only exists on the native FRL path.

### The change

FRL for DCN 4.0.1 landed in **Linux 7.2** (merged 2026-05-11). SteamOS 3.8.24 ships `linux-neptune-616-drm-exec` 6.16.12, so the code is simply not present — this isn't a configuration problem on the SteamOS side.

I checked that rather than assuming it. I extracted `amdgpu.ko` from three neptune kernels — `linux-neptune-616-drm-exec` 6.16.12, `linux-neptune-618-drm-exec` 6.18.33 and `linux-neptune-618` 6.18.38 — and all three carry a **byte-identical** FRL symbol set. None of them contain `dcn401_hpo_frl_stream_encoder`, `link_hdmi_frl` or `link_hwss_hpo_frl`. The `*frl*` symbols they *do* have belong to the DP-to-HDMI PCON path, which is why a DP→HDMI 2.1 converter works today and the native port does not.

So the ask is one of:

1. Backport the DCN 4.0.1 FRL series to the neptune kernel, or
2. Base a future neptune kernel on 7.2+.

If (1), the merged commits are these, all verified present in `v7.2-rc6` (`075b74841bd0`):

| SHA | Subject |
|---|---|
| `c3778921bf0d` | Disable FRL and add module param to enable it |
| `443290d70b01` | Add AV mute wait frames to `dce110_set_avmute` |
| `c216b39fbbc4` | Increase HDMI AV mute wait from 2 to 3 frames |
| `fed376e1f2e3` | Fix kdoc parameter names for DSC padding helper |
| `ee911514a9f8` | Rename `hdmi_frl_borrow_mode` |
| `5726af470517` | Widen FRL debug knobs to unsigned int |
| `1e13b7eb67f9` | Widen `dc_hdmi_frl_flags.force_frl_rate` to unsigned int |

...plus the 14-patch series itself and the ~9 register-header commits that were split out of it before merge. A `git am` of the mailing-list v3 mbox will not compile without those, which is why cherry-picking the merged SHAs is the right route.

### Why this costs you nothing to ship

Upstream ships FRL **disabled by default** — that's what `c3778921bf0d` does — behind `DC_FRL_MASK`, bit 10 of `DC_FEATURE_MASK`. So merely having the code in the neptune kernel changes nothing for any existing user or any existing Deck. Nobody's display behaviour moves unless they explicitly opt in.

That makes this a low-risk backport with a large payoff for desktop/console-form-factor SteamOS on RDNA4 + a HDMI 2.1 TV, which is exactly the Steam Machine use case.

### Two traps worth documenting if you do ship it

Both cost me time, and every guide on the web gets them wrong:

1. The module parameter is spelled **`amdgpu.dcfeaturemask`**. `dc_feature_mask` is the C variable name, not the parameter name. Everyone quotes the latter.
2. The parameter **replaces** the mask, it does not OR into it. So the widely-quoted `0x400` silently clears the default `DC_MULTI_MON_PP_MCLK_SWITCH_MASK` (`0x2`). The correct value is **`0x402`**.

### What still doesn't work, for completeness

Neither of these is a regression and neither blocks the above, but flagging so nobody expects them:

- **HDMI VRR.** 7.2 shipped FRL deliberately *without* HDMI VRR, which is the stated reason FRL is off by default. I checked `amd-staging-drm-next` (`d8ab7636160e`, 1034 commits ahead of `v7.2-rc6`) and the ALLM + HDMI VRR "Gaming Features" series is not there yet either — `allm_mode`, `hdmi_vrr_desktop_mode` and `freesync_pcon_allow_all` are absent from the entire staging tree, while all three appear in the neptune 6.18 tree. So VRR over FRL is a later, separate piece of work for everyone.
- **CEC.** amdgpu registers no CEC adapter for its own HDMI ports, so there's no `/dev/cec*` regardless of kernel. `hdmi_cec_state` reporting `1` is the sink's DDC-advertised capability, not a Linux adapter. Unrelated to FRL.

### One SteamOS-side thing that isn't a kernel issue

Independent of the above, and relevant to anyone testing an alternate kernel on SteamOS: `GRUB_TIMEOUT` in `/etc/default/grub*` has no effect. The generated `grub.cfg`'s steamenv header hardcodes `timeout=0`, so no boot menu is ever shown and an alternate kernel entry is unreachable. The working override is `/efi/EFI/steamos/custom.cfg`, which `/etc/grub.d/41_custom` sources later in the generated config. Might be worth a note in the docs.

### Reproduction details

- SteamOS 3.8.24 (`BUILD_ID=20260716.2`), stock kernel `linux-neptune-616-drm-exec` 6.16.12
- GPU: Navi 48, `1002:7550` (RX 9070 XT); board Gigabyte B850M, Ryzen 7 9800X3D
- Display: LG C9 (HDMI 2.1, 4K120, 40–120 VRR, HDR10)
- Working kernel: mainline `v7.2-rc6` + `-DAMD_PRIVATE_COLOR` in `drivers/gpu/drm/amd/display/amdgpu_dm/Makefile` (keeps gamescope's HDR/colour offload working on a non-Valve kernel — that code is already upstream, just behind a define mainline never sets), booted with `amdgpu.dcfeaturemask=0x402`

Full method, the config used, the raw debugfs captures in both SDR and HDR states, and the install/rollback scripts are here: <https://github.com/sammcj/steam-machine/tree/main/hardware/kernel>

Happy to run any test you'd like on this hardware.

---

## Notes before posting

- Check the repo URL resolves and that `frl-4k120-evidence.txt` is pushed before linking it.
- No serials, account IDs, addresses or private hostnames appear above — keep it that way if you edit it.
- If Valve reply asking for a full `dmesg` with `drm.debug=0x1e`, capture it on the FRL kernel and attach as a file rather than pasting inline.
