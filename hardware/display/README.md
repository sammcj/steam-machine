# Display — 4K120 on the LG C9 (RX 9070 XT)

All of this was verified on-machine on 2026-08-02, not inferred.

## Status: working

**4K120 is working**, over an active DP 1.4 → HDMI 2.1 converter on `DP-1`.
The UGREEN 80397 worked immediately on hotplug — no reboot, no configuration.
The native HDMI port is now unused (`HDMI-A-1: disconnected`).

Measured state:

| | |
| --- | --- |
| Mode | 3840x2160@120, `underflow 0` |
| Link | 4 lanes @ `0x1e` = 30 x 0.27 GHz = **8.1 Gbps/lane HBR3**, 32.4 Gbps total — the DP 1.4 maximum |
| DSC | **active** (`dsc_clock_en 1`), slices 960x108, `dsc_bits_per_pixel 256` = 16 bpp from 30 bpp (1.875:1) |
| Colour | HDR on, Wide Colour Gamut on, 10-bit, RGB 4:4:4 |
| Errors | none logged; clean hotplug, no link retraining |

DSC is doing real work, not decoration. 4K120 RGB 10-bit is ~35.6 Gbps
uncompressed against HBR3's ~25.9 Gbps effective (8b/10b), so it does not fit;
at 16 bpp it lands around 19 Gbps, comfortably inside.

This is a **better** result than native HDMI 2.1 FRL would have given, which is
worth noting given the effort spent chasing FRL: DP + DSC delivers full 4:4:4
10-bit, where the 4:2:0 workaround below could only manage 8-bit with
quarter-resolution chroma.

### VRR does not work through this converter — tested, reverted

**No VRR.** `freesync_pcon_allow_all=1` was tried and is now explicitly pinned
back to `0`. The short version: it did not deliver VRR, and it broke the
picture.

The bypass itself worked — the adapter was identified:

```
[drm] DP-HDMI adapter Freesync PCON whitelist bypassed - Device branch_dev_id : 2818800
```

(2818800 = `0x2B02F0`. Worth reporting upstream if the adapter ever *should* be
whitelisted.)

But VRR stayed off regardless:

```
Vrr: incapable          vrr_range: Min 0 Max 0
```

So the whitelist was never the binding constraint — the UGREEN converter simply
does not pass FreeSync through to the TV. Nothing was gained.

That alone is reason enough to leave it off.

A **vertical glitching seam down the centre of the screen** also appeared at
4K120 during that session, and this section originally blamed the parameter for
it — the driver had gone from one 3840-wide pipe to two ~1922-wide ODM-combine
pipes stitched at x=1920, exactly where the artefact was, so adaptive-sync
changing DML's budgeting looked like the cause.

**That was wrong, twice over.** See the corrections below. Keep the parameter at
`0` because it delivers no VRR, not because it was shown to cause a seam.

#### Correction (2026-08-02, later the same day): ODM combine is on regardless

A seam was noticed again and the parameter was the obvious suspect. It is not
the cause. Re-measured with `freesync_pcon_allow_all=0` confirmed live:

```
$ sudo ./install.sh --status
  freesync_pcon_allow_all    0
VRR:
  sink vrr_range           Min: 0 Max: 0
  engaged                  no (sink reports no VRR range)
pipe topology:
  pipe 0  1922x2160
  pipe 1  1922x2160
  =>                       ODM 2:1 combine
  underflow                0 (clean)
```

So **ODM 2:1 is active with the parameter off**, and the table above is not the
whole story — whatever the single-pipe reading was, it is not what this
configuration settles into.

That fits the arithmetic better than the original theory did. The mode's pixel
clock is `htot 4399 × vtot 2249 × 120 Hz ≈ 1.19 GHz`, well past what one DCN
pipe clocks out, so ODM 2:1 is not a choice DML makes differently depending on
adaptive-sync — it is the only way 4K120 runs at all here. Turning the FreeSync
parameter off could never have removed it.

What follows from that:

- **FreeSync is not being forced on, and cannot be.** The parameter is `0` in
  `modprobe.d` and `0` live; the sink reports `Min: 0 Max: 0`, so there is no
  range for VRR to engage over even if something asked for it.
- `underflow` is `0`, so it was never bandwidth.

#### Second correction: ODM is not the cause either — the seam is gone

The correction above concluded "the seam is an ODM artefact", i.e. the price of
keeping 4K120. **Also wrong.** After the next reboot, with
`freesync_pcon_allow_all=0`, ODM 2:1 is still active —

```
[ 0]: 1920 x 2160
[ 1]: 1920 x 2160
```

— and the seam is **gone**, confirmed by eye. ODM combine is therefore necessary
for 4K120 (the arithmetic above holds) but **not sufficient** to produce the
artefact, so it cannot be the explanation on its own.

**The seam's cause is unresolved and it has not recurred.** Both attempts to
explain it were built on correlation from single before/after observations, with
an uncontrolled variable each time.

The live confound worth recording: this machine lands in either an **X11 or a
Wayland** desktop session depending on how desktop mode is entered (see the
section below), the two behave very differently for colour and compositing, and
the session type was not recorded when the seam was observed. If it returns,
capture `echo $XDG_SESSION_TYPE` alongside the pipe topology before theorising.

Worth testing then, not now: a lower refresh (4K100/4K60, which may fit one pipe)
and a different `dsc_bits_per_pixel` via debugfs — **both are modesets, so read
the "TV is this machine's only console" warning below first.**

`install.sh --status` now reports VRR state and pipe topology directly, so this
is a measurement rather than an eyeball next time.

Diagnosing this again:

```bash
# one pipe at full width = good; two ~1922-wide pipes = ODM combine
sudo grep -A3 '^HUBP:  format' /sys/kernel/debug/dri/0/amdgpu_dm_dtn_log
```

(`odm_combine_segments` in debugfs returns `-95` on this kernel — an error code,
not a reading. Use the HUBP pipe layout instead.)

## Desktop mode lands on X11 or Wayland depending on how you get there

Not a display fault, but it presents as one: colours come out heavily
over-saturated and half of KDE's display settings disappear.

That is an **X11 session**. HDR, Wide Colour Gamut, ICC profile, colour profile
source and brightness control are KWin **Wayland-only** features — on X11 they
all report `incapable` and the controls are hidden. With no colour management,
sRGB content goes unmanaged to a wide-gamut OLED, which is exactly the
over-saturated look.

| How desktop mode is entered | Session |
| --- | --- |
| Steam → Power → Switch to Desktop | **X11** |
| Machine boots into desktop mode | Wayland |

The button calls `steamos-session-select plasma`, and that case in the script
hardcodes `plasmax11.desktop`:

```bash
  plasma)   steamosctl switch-to-desktop-mode plasmax11.desktop
```

That overrides `default-desktop-session` (which is `plasma.desktop`, i.e.
Wayland) — the default is only consulted on a desktop-mode *boot*, not by the
one-shot switch. Confirmed in the journal: the session was started by
`sddm-helper-start-x11user`, not as a fallback from a failed Wayland start.

To get a Wayland desktop:

```bash
steamos-session-select plasma-wayland
```

Avoid `plasma-wayland-persistent` — it also sets `default-login-mode desktop`,
so the machine stops booting into Game Mode. There is no clean fix for the
button itself: `steamos-session-select` lives in `/usr/bin`, which is read-only
and replaced wholesale on every A/B update.

Quickest tell for which session you are in — `echo $XDG_SESSION_TYPE`, or the
connector names: Wayland/DRM uses `DP-1` / `HDMI-A-1`, X11 uses `DisplayPort-0` /
`HDMI-A-0`.

## Install

```bash
sudo ./install.sh          # then reboot
./install.sh --status
```

## The problem

SteamOS offered 3840x2160@60 as the maximum, over a known-good HDMI 2.1 cable
to a TV that does 4K120 from a PS5.

**It is not the cable and not the TV.** The TV's EDID advertises 4K120
correctly — `VIC 118: 3840x2160 120.000000 Hz, 1188.000000 MHz` — and the
HDMI Forum vendor block reports FRL up to 12 Gbps on 4 lanes.

The kernel is the constraint. `6.16.12-valve24.5-neptune-616` has **no HDMI 2.1
FRL**. Verified directly rather than from release notes:

```bash
zstd -d /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst -o amdgpu.ko
strings amdgpu.ko | grep -i frl
```

`DC_FRL_MASK` is absent. Every `FRL` string that *is* present belongs to the
DP-to-HDMI PCON path (`DP-HDMI FRL PCON supported`, `dp_hdmi_frl_max_link_bw_in_kbps`,
`dp_hdmi21_pcon_support`) — adapter-side FRL, which has existed since 2021, not
native HDMI FRL.

Without FRL, amdgpu is capped at HDMI 2.0's 600 MHz TMDS character rate:

| Mode | Pixel clock | TMDS rate | Fits in 600 MHz? |
| --- | ---: | ---: | :--- |
| 3840x2160@60 4:4:4 8-bit | 594 MHz | 594 MHz | yes — this is the ceiling |
| 3840x2160@60 4:4:4 10-bit | 594 MHz | 742 MHz | no |
| 3840x2160@120 4:4:4 8-bit | 1188 MHz | 1188 MHz | no |
| 3840x2160@120 **4:2:0** 8-bit | 1188 MHz | **594 MHz** | yes |
| 2560x1440@120 4:4:4 | 498 MHz | 498 MHz | yes — hence this is offered |

That last row is why 1440p120 and 1080p120 were already in the mode list while
4K120 was not.

## Upstream status (August 2026)

- FRL **merged for Linux 7.2** (Harry Wentland's series, posted 1 May 2026).
  7.2 is still in rc; stable expected late August 2026.
- It is **off by default** because VRR-over-FRL did not land with it. DSC-over-FRL
  did.
- The enabling parameter is widely misquoted online as
  `amdgpu.dc_feature_mask=0x400`. That is wrong twice: the parameter is spelled
  **`dcfeaturemask`**, and it *replaces* the mask rather than OR-ing into it. On
  this machine the current value is `2`, so it would need `0x402`.
- Valve has backported the ALLM / HDMI-VRR half of this work (`allm_mode` and
  `hdmi_vrr_desktop_mode` parameters both exist here) but **not** FRL.
- The out-of-tree work that preceded the merge was tested on DCN 4.0.1 —
  Navi 48, i.e. this exact GPU. RDNA4 is the best-tested path.

Revisit when SteamOS rebases onto 7.2+; at that point `dcfeaturemask=0x402`
becomes the switch and this whole directory can probably be deleted.

## The fix: active DP 1.4 → HDMI 2.1 converter

The GPU emits plain DisplayPort, which has no HDMI Forum entanglement, and the
converter chip does the FRL conversion. Hardware: **UGREEN 80397**, active,
unidirectional, DP 1.4 HBR3, DSC 1.2a, HDCP 2.3, 32.4 Gbps.

DSC is load-bearing here, not marketing:

| Path | Needed | HBR3 available | |
| --- | ---: | ---: | :-- |
| 4K120 RGB 10-bit uncompressed | ~35.6 Gbps | ~25.9 Gbps effective | no |
| 4K120 RGB 10-bit at the **measured** 16 bpp DSC | ~19 Gbps | ~25.9 Gbps effective | yes |

(The second row was originally an estimate of ~12 Gbps; the link actually
negotiated 16 bpp, so the real figure is ~19 Gbps. Still comfortable.)

A **passive** DP++ adapter would not work — those top out at HDMI 2.0 and land
you straight back at 4K60.

### Why `freesync_pcon_allow_all` is pinned to `0`

amdgpu only passes VRR through a protocol converter whose branch device ID is on
an internal whitelist; anything else is downgraded to
`ADAPTIVE_SYNC_TYPE_PCON_NOT_ALLOWED`, giving 120 Hz with no VRR. This option
bypasses the ID check.

Turning it on looks like the obvious move here and **it is the wrong one on this
hardware** — it produced no VRR and a centre-screen seam. See
[VRR does not work through this converter](#vrr-does-not-work-through-this-converter--tested-reverted)
above for the measurements. It is pinned to the driver default explicitly, with
the reasoning in `modprobe.d/amdgpu-display.conf`, so the next person (or the
next me) does not repeat the experiment blind.

The parameter is **read-only at runtime** (`/sys/module/amdgpu/parameters/*` is
mode 0444), so it can only be set at module load — a systemd unit cannot apply
it after boot. Hence modprobe.d, and hence a reboot for any change either way.

## Persistence

Two mechanisms, both required:

- `/etc/modprobe.d/amdgpu-display.conf` — the actual config. `/etc` is an
  overlayfs (upper layer in `/var/lib/overlays/etc/upper`), so this survives
  reboots unconditionally and is writable even when `steamos-readonly` is
  enabled.
- `/etc/atomic-update.conf.d/steam-machine-display.conf` — **`/etc/modprobe.d`
  is not on the default keep list** (`/usr/lib/rauc/atomic-update-keep.conf`),
  so without this the config is silently wiped by the next SteamOS A/B image
  update. `/etc/atomic-update.conf.d/*.conf` *is* on that list, so the
  allowlist entry preserves itself.

No initramfs regeneration is needed: amdgpu is not in the initramfs on this
machine (`lsinitcpio` shows 45 modules, no amdgpu and no DRM drivers), so it
loads from the real rootfs at ~6.3 s and reads `/etc/modprobe.d` directly.
`install.sh` warns if that ever changes.

## Testing

`./test-dp-hdmi-4k120.sh` checks PCON/FRL negotiation, DSC state and the
offered mode list, then sets 4K120 **behind a 20-second dead-man timer** that
restores 4K60 unless you confirm you can still see the screen.

Use it. See the warning below.

## The 4:2:0 fallback — works, but was rejected

Before the converter arrived, native 4K120 *was* made to work, and it is worth
recording exactly how and why it was not kept.

The C9 advertises 4K120 in its plain video data block, but its **YCbCr 4:2:0
Capability Map lists only 4K60/50** — so the driver had no legal way to fit
4K120 into HDMI 2.0. Setting bits 2 and 3 of that bitmap (extension block byte
93, `0x33` → `0x3f`, then fixing the checksum at byte 127) and combining it with
`force_yuv420_output=1` produced a working, stable 4K120:

```
OTG: htot 4399 x vtot 2249 x 120 = 1188 MHz pixel clock
     -> 594 MHz TMDS at 4:2:0, under the 600 MHz limit
     underflow 0
```

`generate-420-edid.py` reproduces the patched EDID; it is applied through
`debugfs/.../edid_override`, which does not persist across reboot.

**Not kept**, because 594 MHz leaves no headroom for 10-bit (that needs
742 MHz). It is 4:2:0 8-bit only: quarter-resolution chroma makes desktop text
soft and fringed, and 8-bit HDR bands visibly. On a 75" OLED that is a bad trade
for the refresh rate. KDE still reports "HDR enabled, 10 bit" in this state —
that is what it *requested*, not what is on the wire.

## Warning: the TV is this machine's only console

An unsyncable mode leaves you with a black screen and no way to type the fix.

This happened during the work above: reverting by clearing
`force_yuv420_output` to 0 **while the mode was still 120 Hz** asked the TV for
4K120 at 4:4:4 — 1188 MHz, roughly double what the link can carry — and it
dropped sync. Recovery had to be done blind.

Unwind in this order, so the signal stays legal at every intermediate step:

1. set a known-good mode (4K60) **first**
2. only then clear `force_yuv420_output`
3. only then reset `edid_override`

and always arm a revert timer before an experimental modeset:

```bash
(sleep 20; kscreen-doctor output.HDMI-A-1.mode.<safe-idx>) &
```

## Useful commands

```bash
# what the TV actually claims
edid-decode /sys/class/drm/card0-HDMI-A-1/edid

# modes currently offered, and which is active (*)
kscreen-doctor -o

# link state
sudo cat /sys/kernel/debug/dri/0/HDMI-A-1/output_bpc
sudo grep -A2 '^OTG:' /sys/kernel/debug/dri/0/amdgpu_dm_dtn_log

# PCON / FRL / DSC negotiation
journalctl -k | grep -iE 'pcon|frl|dsc'
```
