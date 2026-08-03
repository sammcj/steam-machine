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

### Where the artefact actually is — x≈960, not the centre (2026-08-03, evening)

**Every earlier entry in this file, including the "properly measured" one below,
aimed at the wrong place.** They all assumed a seam at the ODM stitch point,
x=1920, because that is where a pipe-split artefact would be. Described
first-hand, it is not there:

- it sits roughly a **quarter** of the way across — **x≈960**, not 1920;
- it is **not a continuous straight line**, but appears in segments down that
  column;
- it is only obvious against **high-contrast edges** — white text on black, a
  bright icon on a dark background.

x=960 is a **DSC slice boundary** (`dsc_slice_width` 960, `dsc_pic_width` 1920
per ODM half, so slices land at 960/1920/2880). Segmented and
contrast-dependent is characteristic of DSC rate control, not of a pipe stitch,
which would be continuous and content-independent.

That reframing came from the description, not from any measurement here — none
of the debugfs fields distinguish the good and bad states.

#### But DSC is an amplifier, not the cause

Tested by turning compression off entirely at 4K120: the artefact was **weaker
but still present**, in the same column. So DSC makes it more visible and does
not create it.

Two hard limits found while testing, both worth knowing before repeating this:

- `dsc_bits_per_pixel` **cannot be raised**. Writing 288 (18 bpp) or 320
  (20 bpp) does not lighten compression — amdgpu drops DSC altogether and
  carries 4K120 some other way. 256 (16 bpp) is the ceiling this link and sink
  will negotiate, so "compress less" is not an available setting.
- `dsc_slice_width` **cannot usefully be moved**. 480 is rejected outright and
  clamped back to 960. 1920 is accepted but reconfigures into a single
  3840-wide pipe with one full-width slice, and **the TV cannot lock to it** —
  no signal, despite debugfs reporting `underflow 0`, `clock_en 1` and a clean
  topology.

That last point is the important methodological one: **amdgpu's debugfs reports
a dead link as healthy.** Every "underflow 0, nothing wrong" reading in this
file is consistent with there being no picture at all, so none of them are
evidence that the output is good.

### RESOLVED: only a full power-off clears it (2026-08-03, late)

A **complete power-off** — not a reboot — cleared the artefact. It stayed clear
through a boot into Game Mode and a switch into Desktop Mode.

`baseline/seam-present.txt` and `baseline/seam-absent.txt` are `--seam` captures
either side of that, at the same 4K120 mode. They are **identical in every
field**, including the DPCD branch firmware revision:

```
$ diff baseline/seam-present.txt baseline/seam-absent.txt
(no output)
```

Same timing, same HBR3 4-lane link, same DSC (on, 16 bpp, 960 slices), same ODM
2:1 with 1922-wide pipes, `underflow 0`, zero link retrains, same `CH7218 hw 0x03
fw 48.0`. Nothing the driver can see distinguishes a working display from a
visibly broken one — which is exactly why days of measurement found nothing.

#### What clears it, tested

| Action | Cleared it? |
| --- | --- |
| Warm reboot | **no** |
| Reboot to EFI firmware and back | **no** |
| Power-cycling the TV at the wall | **no** |
| Unplugging the cable at both ends for 10 s | **no** |
| Switching session (gamescope / KWin X11 / KWin Wayland) | no |
| Dropping to 4K60 or 1440p120 | hides it (single pipe) |
| **Full power-off of the machine** | **yes** |

The reason a reboot is useless: a warm reboot never cuts the GPU rail. The GPU is
not re-POSTed and the DP-bus-powered converter never loses power, so whatever
latched stays latched. Only removing mains power resets either of them.

#### Recovery procedure

**Shut down fully and power off — do not reboot.** Then power on. That is the
only known fix, and it takes under a minute.

If it returns, run `sudo ./install.sh --seam` *before* power-cycling and diff it
against `baseline/seam-absent.txt`. If that diff is empty again, do not spend
time hunting a software cause: nothing in the driver's view of the world differs,
and the answer is the power cycle.

#### What it actually is

Unresolved at the level of "which component", but narrowed to hardware state
below the driver, in one of two places:

- the **GPU's display PHY / link-training calibration**, which survives a warm
  reboot because the card is not re-POSTed; or
- the **CH7218 converter's internal state**.

Ruled out by direct test and recorded above: VRR (`VRR_ENABLED=0`,
`vrr_capable=0`, and KDE will not even draw the Adaptive Sync control because the
sink reports incapable), DSC as a cause (artefact weaker but present with
compression off), the compositor and session type, GPU overclock (overdrive table
all zeros), bandwidth (`underflow 0`), link instability (no retrains), and any
configuration drift (kernel cmdline and amdgpu init byte-identical across clean
and broken boots).

#### Still open

With DSC off, ODM 2:1 on, at 4K120, something at x≈960 remains. Nothing on the
GPU side accounts for a boundary there once slicing is gone — the only structural
edge left is the ODM stitch at 1920. Candidates not yet separated: the wire
format amdgpu falls back to when it drops DSC (unverified — `output_bpc` on this
kernel prints only `Maximum:`, never the current value), and internal
segmentation inside the CH7218 at FRL rates.

### The seam, properly measured (2026-08-03)

It came back on a boot, and this time it was measured rather than guessed at.
Everything below is from one sitting with the artefact visible on screen.

| Test | Result | Rules out |
| --- | --- | --- |
| 4K60 (mode 87) | **1 pipe** 3840x2160, DSC off — no seam | — |
| 4K100 (mode 100) | 2 pipes 1920x2160, DSC on — seam | "100 Hz might fit one pipe" |
| 4K120 (mode 99) | 2 pipes 1920x2160, DSC on — seam | — |
| 4K120, DSC forced off via `dsc_bits_per_pixel` | ODM still 2:1, **DSC off**, seam **unchanged** | DSC / compression ratio |
| Game Mode (gamescope, Wayland) vs Desktop (X11) | seam in **both**, identical | compositor, colour management, session type |
| `underflow` throughout | `0` | bandwidth starvation |
| link retrain / failure messages | none since boot | link instability (as far as the driver reports it) |

So within a single boot the seam tracks ODM 2:1 exactly: present in every mode
that splits the frame, absent in the one that does not.

**But ODM still is not the cause.** 4K120 — and therefore ODM 2:1 — ran
seam-free for two days before the reboot that brought this back. Same mode, same
pipe split, same DSC settings, no seam. ODM is *necessary* for the artefact and
not *sufficient*, which is exactly what the second correction said, and this
time there is a table behind it.

What that leaves: an **intermittent state latched at boot**, somewhere below the
mode-setting layer, that makes the ODM path glitch. It survives modesets, a
full session switch, and DSC being turned off — everything short of a reboot.
Two candidates, not yet separated:

- **DCN pipe/OPP state** programmed badly during this boot's first modeset.
- **The UGREEN 80397 converter's own state.** It is an active device with
  firmware, powered from the DP link, and it is the only thing between the GPU's
  clean-looking output and the TV.

#### A reboot does *not* clear it (2026-08-03, later)

The 2026-08-02 note said the seam went away "after the next reboot", and that
was taken as meaning a reboot resets whatever is wrong. **It does not.** A
reboot was done with the seam visible and it came back identically.

Captured either side of that reboot, every field amdgpu reports is the same:

| | before reboot | after reboot |
| --- | --- | --- |
| session | desktop, X11 | desktop, Wayland |
| timing | htot 4399 x vtot 2249 | identical |
| link | 4 lanes, `0x1e` (HBR3) | identical |
| DSC | on, 256/16 = 16 bpp, slice 960 | identical |
| ODM pipe width | 1920 | **1922** |
| underflow | 0 | 0 |
| link retrains | 0 | 0 |
| seam | present | present |

The pipe width moving between 1920 and 1922 is the only hardware-side
difference, and it is **not** the discriminator either: the 2026-08-02 notes
record 1922 with the seam *and* 1920 without it, and today has 1920 with the
seam. Both widths have now been seen in both states.

So the driver sees nothing wrong in either state, and nothing the driver
controls distinguishes them. That moves the cause downstream of amdgpu
entirely — to the **converter** or the **TV**.

It also explains why a reboot is no help: a warm reboot never cuts power to the
GPU, so the DP-bus-powered UGREEN converter is never reset by one. Only a full
power-off, or physically unplugging it, power-cycles it.

#### Resolved: it tracks FRL, not the GPU

The mode that settled it was **2560x1440@120** — 120 Hz, but only 497 MHz, which
fits HDMI 2.0's 600 MHz TMDS ceiling. So the converter passes it through as
plain TMDS with no FRL and no DSC. It is **clean**.

The full matrix:

| Mode | Pixel clock | DSC | GPU pipes | Converter output | Seam |
| --- | ---: | --- | --- | --- | --- |
| 2560x1440@120 | 497 MHz | off | 1 | TMDS | **no** |
| 3840x2160@60 | 594 MHz | off | 1 | TMDS | **no** |
| 3840x2160@100 | 990 MHz | on | 2 (ODM) | **FRL** | yes |
| 3840x2160@120 | 1187 MHz | on | 2 (ODM) | **FRL** | yes |
| 3840x2160@120, DSC forced off | 1187 MHz | **off** | 2 (ODM) | **FRL** | yes |

The seam appears exactly when the converter has to drive its HDMI output with
**FRL** (above the 600 MHz TMDS ceiling), and never when it can use plain TMDS.
It is independent of refresh rate as such — 120 Hz is fine at 1440p — and
independent of DSC, which was forced off at 4K120 with no change whatsoever.

ODM 2:1 remains perfectly correlated too, because every mode over 600 MHz here
also needs ODM: there is no mode on this display that gives one without the
other, so they cannot be separated by mode choice alone. What separates them is
everything else:

- the GPU's own reporting is **clean and identical** in the good and bad states
  — underflow 0, no link retrains, HBR3 4 lanes verified, same timing, same DSC
  parameters (see the reboot table above);
- VRR is off at the DRM level, not just per KDE: `VRR_ENABLED = 0` on every
  CRTC and `vrr_capable = 0` on every connector, with
  `freesync_pcon_allow_all=0` and `freesync_video=0`;
- no overclock or undervolt — the overdrive table is all zeros
  (`OD_SCLK_OFFSET: 0Mhz`, `OD_VDDGFX_OFFSET: 0mV`, MCLK at stock);
- the kernel command line and every amdgpu init line are byte-identical between
  the boot that ran 4K120 clean for seven hours and the boots that seam;
- and this same GPU at this same ODM 2:1 configuration *did* run clean.

So the fault is in the **FRL path**, downstream of amdgpu: the converter's FRL
encoder, or the HDMI cable carrying FRL, or the TV port receiving it. Nothing on
the GPU side is implicated.

#### What actually failed, and what to do

It is a hardware fault that developed — it worked for days, then stopped, with
no configuration change on either side, and no reset recovers it. Ruled out by
direct test: reboot, unplugging the cable at **both** ends for 10 s (so the
bus-powered converter was fully power-cycled), and power-cycling the TV.

Ranked by cost, the remaining suspects are all in the FRL chain:

1. **The HDMI cable, converter → TV.** Cheapest to swap and the failure mode
   fits precisely: a cable that is comfortably fine carrying 594 MHz TMDS can
   fail at FRL's much higher signalling rate. Needs a certified *Ultra High
   Speed* (48 Gbps) cable — "High Speed" or "Premium High Speed" is a 2.0 cable
   and will not do FRL reliably.
2. **The TV's HDMI port.** Try another input, and confirm *HDMI Deep Colour* is
   enabled for whichever port is in use (the C9 gates 4K120 on it per port).
3. **The UGREEN 80397 converter itself.** The only active component in the
   chain, and FRL encoding is the hardest thing it does.

Until one of those is swapped, the usable modes are **3840x2160@60** for the
desktop (RGB 10-bit, HDR, no compression) and **2560x1440@120** for high-refresh
games. Both are seam-free for the reason in the table: neither needs FRL.

IPS was considered and dropped: this GPU has no `amdgpu_dm_ips_status` in
debugfs at all, so the RDNA idle-power-state corruption class does not apply
here.

#### Capturing it next time

```bash
sudo ./install.sh --seam
```

One read-only command, no modeset, safe to run while the artefact is on screen.
It records session type, timing, link state, DSC state, pipe topology, underflow
and link-error count together — the exact set that took three sittings to work
out was the relevant one. **Run it before changing anything**, because every
wrong theory in this file came from changing one thing and eyeballing the
result.

(`odm_combine_segments` in debugfs returns `-95` on this kernel — an error code,
not a reading. The HUBP pipe layout is the reliable source, and `--seam` parses
it. Careful with the columns by hand: the OTG section labels rows `[0]:` and the
HUBP section `[ 0]:`, and that one space shifts every awk field — it has now
produced two wrong readings in this repo.)

## Desktop mode lands on X11 or Wayland depending on how you get there

Not a display fault, but it presents as one: colours come out heavily
over-saturated and half of KDE's display settings disappear.

That is an **X11 session**. HDR, Wide Colour Gamut, ICC profile, colour profile
source and brightness control are KWin **Wayland-only** features — on X11 they
all report `incapable` and the controls are hidden. With no colour management,
sRGB content goes unmanaged to a wide-gamut OLED, which is exactly the
over-saturated look.

| How desktop mode is entered | Session (stock) | Session (with the shim below) |
| --- | --- | --- |
| Steam → Power → Switch to Desktop | **X11** | Wayland |
| Machine boots into desktop mode | Wayland | Wayland |

The button calls `steamos-session-select plasma`, and that case in the script
hardcodes `plasmax11.desktop`:

```bash
  plasma)   steamosctl switch-to-desktop-mode plasmax11.desktop
```

That overrides `default-desktop-session` (which is `plasma.desktop`, i.e.
Wayland) — the default is only consulted on a desktop-mode *boot*, not by the
one-shot switch. Confirmed in the journal: the session was started by
`sddm-helper-start-x11user`, not as a fallback from a failed Wayland start.

To get a Wayland desktop, use the `wayland` shell function (installed by
`install.sh`, sourced from `bashrc.d/wayland.sh`):

```bash
wayland          # confirms first, then restarts the session into Wayland
wayland -y       # skip the confirmation
wayland status   # what session am I on, and does it have colour management
```

Or the desktop shortcut — **Switch to Wayland**, on the Desktop and in the
application launcher. It runs `bin/wayland-switch`, which asks the same question
in a `kdialog` box instead of the terminal.

Both wrap `steamos-session-select plasma-wayland`, which you can also run
directly. The confirmation is there because the switch tears down the desktop
and takes every open window with it — and a desktop icon is easy to double-click
by accident.

Editing `bashrc.d/wayland.sh` or `bin/wayland-switch` takes effect immediately —
no reinstall. The `.desktop` files are generated from
`desktop/steam-machine-wayland.desktop.in` with the `Exec` path substituted, so
edit the template, not the installed copies. They live under `/home/deck`, which
is its own partition, so unlike everything in `/etc` they need no
`atomic-update.conf.d` keep entry to survive a SteamOS update.

Avoid `plasma-wayland-persistent` — it also sets `default-login-mode desktop`,
so the machine stops booting into Game Mode.

### Fixing the button itself

The two escape hatches above are recovery, not a fix — they only help *after*
you have already landed in a wrecked-looking X11 session. The button is now
fixed at source.

Steam invokes `steamos-session-select` **by name, through `PATH`**, and
`/etc/profile` builds a `PATH` that puts `/usr/local/bin` ahead of `/usr/bin`.
So `/usr/local/bin/steamos-session-select` (from
`bin/steamos-session-select-shim`) shadows Valve's copy without editing or
replacing it — theirs keeps updating normally, which matters because editing a
Valve-shipped file permanently shadows all their future versions of it.

The shim rewrites exactly one thing, the bare `plasma` alias, to
`plasma-wayland`. Everything else — `gamescope`, `plasma-wayland`, and both
`*-persistent` forms — is passed straight through, so `plasma-x11-persistent`
still works if X11 is ever wanted deliberately, as does
`/usr/bin/steamos-session-select plasma` by full path.

Verify it is actually on the path Steam takes, rather than assuming:

```bash
./install.sh --status          # reports the shim, what PATH resolves, and the mapping
journalctl -t steam-machine-session   # one line each time the rewrite fires
```

**Persistence is the trap here.** `/usr/local` is on the rootfs subvolume, which
a SteamOS A/B update replaces wholesale — so unlike everything else in this
directory, the shim is deleted by every OS update, silently, and the first
symptom is the colours going wrong again months later.
`steam-machine-display.service` reinstalls it at every boot;
`/etc/systemd/system/*.service` **is** on the default keep list, so the unit
itself survives to do the repair. The unit unlocks the rootfs only when it
actually has work to do, and restores `steamos-readonly` to the state it found
it in. Tested by deleting the shim, re-locking the rootfs and starting the unit.

That is why the boot unit exists and why the shim is not simply "installed once"
— confirmed with `./install.sh --status`, which reports the unit as well as the
file.

Quickest tell for which session you are in — `echo $XDG_SESSION_TYPE`, or the
connector names: Wayland/DRM uses `DP-1` / `HDMI-A-1`, X11 uses `DisplayPort-0` /
`HDMI-A-0`.

## Install

```bash
sudo ./install.sh          # then reboot
sudo ./install.sh --status
sudo ./install.sh --seam   # capture display state while the 4K120 seam is visible

# TV showing "no signal" while the machine is plainly running: force a re-detect
sudo ./bin/display-redetect --force
./bin/display-redetect --status      # no root needed, touches nothing
```

Only the `modprobe.d` half needs the reboot (amdgpu parameters are read-only at
runtime). The session-select shim takes effect immediately.

## Persistence summary

| File | Survives reboot | Survives SteamOS A/B update | How |
| --- | --- | --- | --- |
| `/etc/modprobe.d/amdgpu-display.conf` | yes (`/etc` overlay) | yes | `atomic-update.conf.d` keep entry + `--boot` |
| `/etc/atomic-update.conf.d/steam-machine-display.conf` | yes | yes | on the default keep list itself |
| `/etc/systemd/system/steam-machine-display.service` | yes | yes | `/etc/systemd/system/*.service` is keep-listed |
| `/usr/local/bin/steamos-session-select` | yes | **no** | rootfs subvol is replaced — reinstalled by the boot unit |
| `~/.bashrc` line, Desktop shortcuts | yes | yes | `/home` is a separate partition |
| `/etc/systemd/system/steam-machine-display-{redetect,redetect-boot,redetect-resume,hotkey}.service` | yes | yes | `/etc/systemd/system/*.service` is keep-listed |
| `/etc/udev/rules.d/99-steam-machine-display-redetect.rules` | yes (`/etc` overlay) | yes | `atomic-update.conf.d` keep entry + `--boot` |

The re-detect scripts themselves live in the repo on `/home` and are run from
there by the units, so they need no rootfs unlock and cannot be deleted by an
A/B update — hence `RequiresMountsFor=/home/deck` on each unit.

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

## What the converter actually is (read from DPCD, 2026-08-03)

The UGREEN 80397 identifies itself over DP AUX. Read it directly rather than
trusting the box:

```bash
sudo dd if=/dev/drm_dp_aux0 bs=1 skip=$((0x500)) count=16 status=none | xxd
# 2b02 f043 4837 3231 3803 3000 0000 0000
```

| DPCD | Field | Value |
| --- | --- | --- |
| 0x500-0x502 | Branch IEEE OUI | `2B:02:F0` |
| 0x503-0x508 | Branch device ID | **`CH7218`** |
| 0x509 | Branch hardware rev | `0x03` |
| 0x50A-0x50B | Branch firmware rev | **48.0** |

So the silicon is a **Chrontel CH7218**, and the OUI matches the
`branch_dev_id : 2818800` (= `0x2B02F0`) that amdgpu logs when
`freesync_pcon_allow_all=1` bypasses the whitelist.

### Firmware is updatable, but only from Windows

Chrontel ship a "Chip FW Update Tool" (Windows executable) that flashes the
CH7218 over IIC/USB/AUX/SPI, and UGREEN distribute it for their other
CH7218-based adapters — the DP134 (85564) and DP135 (85596) — bundled with an
image named `CH7218A-IMG.G000.07.00.54`. There is **no fwupd/LVFS support**:
Chrontel does not appear on LVFS at all, and `fwupdmgr` on this machine does not
enumerate the converter (its DP plugins cover Parade, Synaptics and Kinetic
only). So there is no Linux update path.

Two caveats before treating this as a fix for the seam:

- The documented reason UGREEN ship that firmware is **HDR/VRR unavailability**,
  not image artefacts. There is no report tying a CH7218 firmware revision to
  banding or corruption.
- No UGREEN tool for the **80397** specifically was found — only for the DP134
  and DP135. Flashing an image built for a different SKU is not obviously safe.

### Do not transfer CAC-1085 reports to this adapter

Searching for "DP to HDMI 2.1 adapter, vertical line at 120 Hz" turns up a good
deal of material, and essentially all of it concerns the **Club3D CAC-1085** —
including a "line of noise" thread and reports of 4K120 degrading after about an
hour. That adapter uses a **Realtek RTD2173**, a different chip entirely. Those
reports do not apply here and should not be used as evidence about the CH7218.

The one genuinely documented CH7218 defect is a Linux amdgpu bug: the driver did
not whitelist this PCON for VRR, so VRR silently reports `Min: 0 Max: 0` — which
is exactly what this machine sees. A patch adding CH7218 to the VRR whitelist has
been posted upstream. That explains the VRR result recorded above, and is
unrelated to the seam.

## The fix: active DP 1.4 → HDMI 2.1 converter

The GPU emits plain DisplayPort, which has no HDMI Forum entanglement, and the
converter chip does the FRL conversion. Hardware: **UGREEN 80397**, active,
unidirectional, DP 1.4 HBR3, DSC 1.2a, HDCP 2.3, 32.4 Gbps.

DSC is required here, not marketing:

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

## "No signal" when the TV is switched on after the machine (2026-08-04)

**Symptom.** Wake the machine by WoL with the TV off, walk in later, switch the
TV on: no signal. SSH in and everything reports healthy — `DP-1 connected`,
`crtc-0 active=1`, 4 lanes at `0x1e` (HBR3), `dsc_clock_en 1`, `underflow 0`.
The GPU has been happily transmitting 4K120 the whole time. The TV simply never
gets a handshake it can latch onto.

**Cause.** The DP sink is the converter, not the TV. The CH7218 keeps HPD
asserted and answers EDID from its own cache whether the TV is on, off or in
standby — at boot with the TV off, gamescope logged `Connector DP-1 -> GSM - LG
TV` and read its colorimetry, then set 4K120 into a converter with nothing
downstream. When the TV later wakes, the converter does not re-assert HPD, so
nothing re-detects and nothing re-modesets. Confirmed: **zero hotplug uevents**
across an entire boot containing three TV power cycles.

This is not boot-specific. Any modeset or blank that lands while the TV is
off strands it the same way — resume, a session switch, a screen blank.

### There is no way to detect it from this side — measured, not assumed

Every channel that could carry "the TV is awake" was sampled across a TV power
cycle (35 samples over 128 s, TV switched off mid-window):

| Channel | Result |
| --- | --- |
| DPCD `SINK_COUNT` (0x200) | `0x41` in both states — reports a sink unconditionally |
| DPCD pages 0x0000/0100/0200/0300/2000/2100/2200/3000 (2048 B) | bit-identical |
| DP 1.4a protocol-converter status page (0x3000) | all zeroes — device reports DPCD **1.2**, so these registers do not exist |
| Branch info (0x500) | identity only — see the CH7218 section above |
| EDID over DDC (`i2c-11`, addr 0x50) | answered from converter cache in both states |
| DDC/CI (addr 0x37) | **absent in both states** — `ddcutil` reads the EDID but reports "Invalid display"; `getvcp D6` returns `DDCRC_RETRIES`/`EREMOTEIO` |
| HDMI audio ELD | `monitor_present 1` in both states — derived from the connector, so cached too |

The converter terminates the link and answers everything itself. A polling
daemon has nothing to poll, so the fix cannot be detection — it has to be
redoing the modeset while the TV is awake.

### The fix: force a replug

Writing `0` then `1` to the connector's debugfs `trigger_hotplug` makes the
compositor drop the output and re-detect it. Both gamescope and kwin handle it.

```bash
sudo sh -c 'echo 0 > /sys/kernel/debug/dri/0/DP-1/trigger_hotplug
            sleep 2
            echo 1 > /sys/kernel/debug/dri/0/DP-1/trigger_hotplug'
```

A bare `echo 1` is **not** enough — measured. The connector never leaves the
connected state, so userspace re-probes, sees no change and does nothing. The
disconnect is the part that does the work.

Under gamescope this is clean: a brief black frame, Steam stays up. Under
Plasma it also restarts `plasmashell`, because kwin briefly sees zero outputs —
harmless, but the desktop redraws.

### Triggers

`bin/display-redetect` wraps the above with a lock, a per-trigger debounce and
connector auto-detection. Four things call it:

| Trigger | Unit | When | Covers |
| --- | --- | --- | --- |
| **Shift+Esc** | `steam-machine-display-hotkey.service` | any time | everything — the escape hatch that works when the screen is already black |
| Controller connect | udev rule → `steam-machine-display-redetect.service` | DualSense connects, USB or BT | walking in and turning the TV on |
| Boot | `steam-machine-display-redetect-boot.service` | +25 s after `graphical.target` | TV already on at boot |
| Resume | `steam-machine-display-redetect-resume.service` | +8 s after `suspend.target` | TV already on at resume |

Each trigger keeps its **own** debounce stamp
(`/run/steam-machine-display-redetect.<tag>.stamp`). Sharing one would let the
speculative fire at boot — which achieves nothing if the TV is off — suppress
the controller trigger a few seconds later, which is the one that matters.

The hotkey daemon reads evdev directly rather than binding through xbindkeys
(Game Mode) or kglobalaccel (Desktop), because it has to work in both plus a
bare TTY, and has to survive a session switch. It runs as root and inspects
**only** `KEY_ESC` and the two Shift keys; nothing is logged or buffered. It
does not grab the devices, so Esc still reaches whatever has focus.

### What still is not covered

Pick up the controller *before* switching the TV on and the re-detect fires
into a dark TV and achieves nothing. Shift+Esc is the fallback. The ordering
that avoids the whole problem is **TV on first, then wake the machine** — then
the session's own modeset lands with the TV awake and no trigger is needed.

Ruled out as fixes: waking the TV over the network (it is deliberately off the
LAN — LG's webOS phones home), and going back to the native HDMI port (real HPD
from the TV, but 4K60 only until amdgpu gets FRL on Linux 7.2+).

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
