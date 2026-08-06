# Kernel - HDMI 2.1 FRL for 4K120 on the native HDMI port

## Status: working, persistent, and the default boot entry

**4K 120 Hz, RGB 4:4:4, 12 bpc, uncompressed, HDR10, zero underflow - over the GPU's native HDMI port**, on a hand-built mainline **Linux 7.2-rc6**. Achieved 2026-08-06. The UGREEN DP→HDMI converter is out of the chain entirely.

This is strictly better than what the converter delivered: it managed 10 bpc *with* DSC, plus intermittent glitching and no CEC. See [hardware/display/](../display/README.md) for that setup, which this replaces.

Full measurement capture, with the raw debugfs output it was read from: [`frl-4k120-evidence.txt`](frl-4k120-evidence.txt).

**HDMI VRR and ALLM work too**, since 2026-08-06 - 40-120 Hz, `vrr_capable 1` - via AMD's unmerged 4-patch series ported onto this build. See [patches/](patches/).

**It survives SteamOS updates** (since 2026-08-06), via a cached artefact tarball under `/home` and a keep-listed systemd unit that reinstalls whatever an A/B update deleted. It is also the **default boot entry**, with a 10-second menu to pick the stock Valve kernel instead. See [Install](#install) and [How it survives updates](#how-it-survives-updates).

## TL;DR

Everything below this section is the reasoning. If you just want it working:

> **No warranty.** This replaces your kernel and edits your bootloader config on hardware that is not mine; it worked here, it may not work for you, and you run it entirely at your own risk. Read [Warning](#warning) before starting.

**You need this if** you have an RDNA4 Radeon (RX 9000 series) on SteamOS, a HDMI 2.1 display, and the HDMI port refuses anything above 4K60. No Valve kernel has native FRL, so no setting fixes it - it needs a different kernel.

**Before you start:** clone this repo somewhere permanent under `/home` and leave it there. `install.sh` registers a systemd unit pointing at an absolute path into it, and that unit is what puts the kernel back after a SteamOS update. Moving the repo later means re-running `--install`.

All commands below are run from `hardware/kernel/` in this repo.

1. **Get the sources** - Valve's kernel source package (for its config), plus mainline `v7.2-rc6` fetched into the same git repo. [Commands](#1-get-valves-source-tree).
2. **Apply the patches** - all five, in order, are in [patches/](patches/):
   ```bash
   cd /home/deck/kernel-frl/build72
   git checkout -b frl v7.2-rc6
   git am /home/deck/git/steam-machine/hardware/kernel/patches/*.patch
   ```
   `0001` keeps gamescope's HDR offload working on a non-Valve kernel - take it regardless. `0002`-`0005` are AMD's unmerged VRR/ALLM series; skip them and you get 120 Hz without VRR.
3. **Build it** in a container - the rootfs is read-only and has no `bc`/`flex`/`bison`. Seed the config from Valve's so you keep what SteamOS depends on. ~25 min on a 9800X3D. [Full steps](#3-config-and-build):
   ```bash
   cd /home/deck/kernel-frl
   podman build -t kbuild:arch -f Containerfile .
   podman run --rm -v $PWD:/work -w /work/build72 localhost/kbuild:arch make olddefconfig
   podman run --rm -v $PWD:/work -w /work/build72 localhost/kbuild:arch make -j$(nproc) all
   podman run --rm -v $PWD:/work -w /work/build72 localhost/kbuild:arch \
     make -j$(nproc) modules_install INSTALL_MOD_PATH=/work/stage INSTALL_MOD_STRIP=1
   ```
   `INSTALL_MOD_STRIP=1` is not optional in practice: without it the module tree is 2.2 GB instead of 178 MB, and `/` has under 800 MB free.
4. **Rebuild any out-of-tree modules** you depend on, against the new tree, before you reboot into it. Here that is `it87` (fan and temp sensors) and `btusb_mt7902` (Bluetooth) - lose them silently and you will blame the kernel. [Details](#4-out-of-tree-modules).
5. **Copy the modules into place**, then install:
   ```bash
   sudo cp -a /home/deck/kernel-frl/stage/lib/modules/<kver> /usr/lib/modules/
   sudo depmod <kver>
   sudo ./install.sh --cache     # pack kernel + modules into ~/.cache/frl-kernel
   sudo ./install.sh --install   # deploy, initramfs, boot entry, self-heal service
   ```
6. **Reboot.** A 10-second menu appears with the FRL entry preselected. The stock Valve kernel is one arrow-key up, and GRUB falls back to it automatically if the FRL entry cannot load - so a bad build costs you a reboot, not a lockout. That safety is built into `install.sh`; you do not configure it.
7. **Check it:**
   ```bash
   sudo ./install.sh --status
   ```
   Every component line should read `yes`, and `grub.cfg is stock : yes`. The link-state block only appears when you are running the FRL kernel: `HPO` populated with `ACTIVE` and your horizontal resolution means the native FRL path is carrying the link, and `vrr_range` should show your display's own VRR range rather than `Min: 0 Max: 0` (this TV reports `40`-`120`).

**The one non-obvious setting:** the kernel parameter is `amdgpu.dcfeaturemask=0x402`, not the `dc_feature_mask=0x400` every guide on the web quotes. Both halves of that matter - [why](#two-traps-in-the-widely-quoted-incantation). `install.sh` puts it on the FRL boot entry for you.

**To undo it all:** boot the stock kernel from the menu, then `sudo ./install.sh --uninstall`.

**After a SteamOS update:** nothing, it repairs itself - but [read this](#after-a-steamos-update) for what to expect and how to check.

---

## Background

### What was measured

|                       |                                                                             |
| --------------------- | --------------------------------------------------------------------------- |
| Mode                  | 3840×2160 @ 120 Hz                                                          |
| Pixel clock           | **1188.00 MHz** (htotal 4400 × vtotal 2250 × 120)                           |
| HDMI 2.0 TMDS ceiling | 600 MHz - the link is running at **1.98×** it                               |
| Lanes                 | 4                                                                           |
| Pixel format          | RGB 4:4:4                                                                   |
| Bit depth             | 12 bpc                                                                      |
| DSC                   | `CLOCK_EN 0` - uncompressed                                                 |
| ODM segments          | 0 - single pipe, no combine                                                 |
| Underflow             | `0h` on every active pipe                                                   |
| HDR                   | `Colorspace = 9` (`DRM_MODE_COLORIMETRY_BT2020_RGB`) while an HDR game runs |
| Content type          | `4` (Game) - drives HDMI ALLM                                               |
| VRR                    | 40-120 Hz, `vrr_capable 1` (added 2026-08-06, see [patches/](patches/))    |

The pixel clock is the proof on its own. 600 MHz is a hard ceiling for TMDS signalling; 1188 MHz is only reachable over FRL. (The DTN log prints the raw OTG registers, which hold total-1 - `dcn10_optc.c` programs `OTG_H_TOTAL = h_total - 1` - so the `4399 × 2249` it shows is the standard CTA-861 4400 × 2250 timing.)

**Note the ODM row.** [hardware/display/](../display/README.md) records that ODM 2:1 combine is mandatory for 4K120 on this machine, because ~1.19 GHz is more than one DCN pipe can clock out. That holds for the **DP + converter** path it was measured on. It does not hold here: over native FRL the HPO block reports `ODM Segments 0` and every HUBP pipe is the full 3840 wide, not the ~1922 that ODM 2:1 produces. Single pipe, no combine, at the same pixel clock. Worth remembering, because the centre-screen seam that was investigated at length on the converter was suspected of being an ODM stitching artefact - this path does not stitch at all.

Two further confirmations that the *native* FRL path is what's carrying it, rather than the old DP-to-HDMI PCON code that has been in amdgpu for years:

- dmesg contains `hdmi_frl_status_polling_workque` - a workqueue created only by the 7.2 FRL code.
- `amdgpu_dm_dtn_log` populates the **HPO** block (`Lanes 4`, `Borrow ACTIVE`), the FRL stream encoder path. On the converter this block was empty and the DP link block was populated instead.

For HDR specifically, `Colorspace = 9` is the exact test gamescope uses in `CDRMConnector::IsHDRActive()`. On the SDR desktop the same property reads `0`; it flips to `9` when an HDR title starts, and the composited plane's HUBP surface format changes `8h` → `18h` (32-bit ARGB8888 → a 64-bit half-float surface).

## Why no SteamOS kernel could do this

The `amdgpu` in every Valve kernel has no native HDMI 2.1 FRL, which caps the HDMI port at 600 MHz TMDS. 4K120 4:4:4 needs ~1188 MHz, so the port simply could not light the mode.

Verified rather than assumed - the `amdgpu.ko` was extracted from the Valve packages and its symbol table compared:

- `linux-neptune-616-drm-exec` 6.16.12 (what SteamOS 3.8 ships)
- `linux-neptune-618-drm-exec` 6.18.33
- `linux-neptune-618` 6.18.38

**All three have a byte-identical FRL symbol set.** The `*frl*` symbols they do contain (`dc_link_bw_kbps_from_raw_frl_link_rate_data`, `DC_LINK_ENCODING_HDMI_FRL`, the `dml*_hdmifrl` naming) all belong to the DP-to-HDMI PCON path - configuring an *external* converter's FRL, not driving FRL from the GPU's own encoder. None of them contain `dcn401_hpo_frl_stream_encoder`, `link_hdmi_frl` or `link_hwss_hpo_frl`.

Upstream, FRL landed in **Linux 7.2** ([Phoronix](https://www.phoronix.com/news/Linux-7.2-DRM)), from Harry Wentland's `[PATCH RESEND v3 00/14] HDMI FRL and DSC Support for amdgpu` - 14 patches, 179 files, +15,176/-120. DCN 4.0.1 (this GPU) is explicitly in scope: the series adds `dcn401_hpo_frl_stream_encoder.c` and +220 lines to `dcn401_dio_link_encoder.c`.

It ships **disabled by default**, gated behind `DC_FRL_MASK = (1 << 10)` in `drivers/gpu/drm/amd/include/amd_shared.h`, because HDMI VRR is not ready and AMD consider FRL-without-VRR a regression for existing users.

### Two traps in the widely-quoted incantation

Every article says to boot with `amdgpu.dc_feature_mask=0x400`. That is wrong twice:

1. **The parameter is spelled `dcfeaturemask`.** `dc_feature_mask` is the name of the C variable, not the module parameter. Confirmed with `modinfo`.
2. **It replaces the mask, it does not OR into it.** The default on this machine is `2` (`DC_MULTI_MON_PP_MCLK_SWITCH_MASK`). Passing `0x400` would silently turn that bit *off*. The correct value is **`0x402`**.

## How it was built

Reproducible from scratch. The whole thing took about two hours, most of it unattended compile time.

Everything the kernel carries on top of stock mainline is in [patches/](patches/) as `git format-patch` output, with provenance for each. Applying them in order onto a clean `v7.2-rc6` reproduces the running kernel:

```bash
git checkout -b frl-rebuild v7.2-rc6
git am /home/deck/git/steam-machine/hardware/kernel/patches/*.patch
```

### 1. Get Valve's source tree

Valve's kernel git is at `gitlab.steamos.cloud/jupiter/linux-integration`, but anonymous HTTPS git returns 403 and the web UI is behind Anubis. The PKGBUILD's `source=` is `git+ssh://`, which needs credentials.

The way in is the **source package**, which embeds a full bare git repo at the exact build tag:

```bash
curl -fLO https://steamdeck-packages.steamos.cloud/archlinux-mirror/sources/jupiter-3.8/linux-neptune-618-drm-exec-6.18.33.drmexec.valve2-1.1.src.tar.gz
tar -xzf linux-neptune-618-drm-exec-*.src.tar.gz
# -> linux-neptune-618-drm-exec/archlinux-linux-neptune/  (bare repo, 3.4 GB pack)
# -> linux-neptune-618-drm-exec/config.x86_64             (the full kernel config)
# -> linux-neptune-618-drm-exec/config-neptune            (Valve's config fragment)
```

3.7 GB, and the mirror throttles a single connection to ~60 Mbit/s regardless of local bandwidth (`Accept-Ranges: bytes` is supported, so parallel range requests would be faster; `aria2c` is not installed and the rootfs is read-only, but plain `curl -r` in parallel works).

That repo is a fork of mainline and shares its history, so pulling upstream into it is incremental:

```bash
cd linux-neptune-618-drm-exec/archlinux-linux-neptune
git remote add torvalds https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
git fetch --no-tags torvalds tag v7.2-rc6
git worktree add ../../build72 v7.2-rc6
```

### 2. Restore the Valve colour properties

Gamescope offloads HDR colour management onto DCN hardware via AMD's driver-private per-plane properties (`AMD_PLANE_CTM`, `BLEND_TF`, `SHAPER_LUT`, `LUT3D`, `HDR_MULT`, ...). SteamOS enables them with `CONFIG_DRM_AMD_COLOR_STEAMDECK=y`, which does not exist upstream.

That turned out to be a non-issue. **All of the code is already in mainline** - in `amdgpu_dm_color.c`, `amdgpu_dm_crtc.c` and `amdgpu_dm_plane.c` - guarded by `#ifdef AMD_PRIVATE_COLOR`, a bare define mainline never sets. Upstream's own documentation in `amdgpu_dm_color.c` says the properties are exposed "when the kernel is built explicitly with `-DAMD_PRIVATE_COLOR`".

Valve's commit (`0f3a9b934bc3`, authored by Melissa Wen at Igalia, tagged `[NOT-FOR-UPSTREAM]`) is nothing more than a 7-line Kconfig entry plus six one-line `#ifdef` renames. Cherry-picking it onto 7.2 conflicts in three files because it dates from 2023. One line in `drivers/gpu/drm/amd/display/amdgpu_dm/Makefile` achieves the same thing with no conflicts:

```make
subdir-ccflags-y += -DAMD_PRIVATE_COLOR
```

Verified afterwards: all five properties gamescope checks for are present in the built `amdgpu.ko`, and HDR offload works.

### 3. Config and build

Seed from Valve's config so the machine keeps everything it depends on - `SCHED_CLASS_EXT=y` for the installed `scx-scheds`, `DEBUG_INFO_BTF=y`, the lot:

```bash
cd build72
cat ../linux-neptune-618-drm-exec/config.x86_64 > .config
cat ../linux-neptune-618-drm-exec/config-neptune >> .config
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-frlprobe"/; \
        s/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' .config
```

The `override: reassigning to symbol ...` warnings from `olddefconfig` are the neptune fragment overriding the base config. That is what it is for.

Build in a container - the host is missing `bc`, `flex` and `bison`, and the rootfs is read-only:

```bash
podman build -t kbuild:arch -f Containerfile .     # archlinux:base-devel + kernel deps
podman run --rm -v $PWD:/work -w /work/build72 kbuild:arch make olddefconfig
podman run --rm -v $PWD:/work -w /work/build72 kbuild:arch make -j$(nproc) all
```

About 25 minutes on the 9800X3D.

### 4. Out-of-tree modules

`it87` (sensors) and `btusb_mt7902` (Bluetooth) must be rebuilt per-kernel or the probe boot loses fan/temp readings and Bluetooth. Both build cleanly against 7.2-rc6:

```bash
# in the container, against /work/build72
make -C /work/build72 M=$PWD modules                       # it87
make KVER=7.2.0-rc6-frlprobe KSRC=/work/build72            # btusb_mt7902
```

Install into `/usr/lib/modules/<kver>/updates/` and `depmod`, matching where [hardware/sensors/](../sensors/README.md) and [hardware/bluetooth/](../bluetooth/README.md) put them.

## Install

```bash
sudo ./install.sh --cache      # pack the built kernel into /home (once, after a build)
sudo ./install.sh              # deploy it and make it the default boot entry
sudo ./install.sh --status     # what is installed, plus the live FRL link state
sudo ./install.sh --uninstall  # remove everything, back to stock
```

`--cache` reads the build tree at `/home/deck/kernel-frl/build72` (override with `FRL_BUILD_TREE`) and the installed modules, and writes a **172 MB** tarball to `/home/deck/.cache/frl-kernel/`. That tarball is the thing that makes reinstalling after an update cheap - no rebuild, no container, no network.

### What lands on the machine

| Path                                                  | What                                            | Survives an update?      |
| ----------------------------------------------------- | ----------------------------------------------- | ------------------------ |
| `/boot/frl/vmlinuz-linux-frlprobe`                    | the kernel                                      | no - restored from cache |
| `/boot/frl/initramfs-linux-frlprobe{,-fallback}.img`  | generated by mkinitcpio                         | no - regenerated         |
| `/usr/lib/modules/7.2.0-rc6-frlprobe/`                | modules, incl. `updates/{it87,btusb_mt7902}.ko` | no - restored from cache |
| `/etc/mkinitcpio.d/linux-frlprobe.preset`             | so mkinitcpio knows about it                    | no - rewritten           |
| `/efi/EFI/steamos/custom.cfg`                         | menu timeout, the FRL entry, and `set default`  | no - regenerated         |
| `/etc/systemd/system/steam-machine-kernel.service`    | runs `--boot` at every boot                     | **yes** - keep-listed    |
| `/etc/atomic-update.conf.d/steam-machine-kernel.conf` | the allowlist entry itself                      | **yes**                  |

Everything authoritative is under `/home`: this repo, plus the cache tarball. The 40 GB source and build tree in `/home/deck/kernel-frl/` are only needed to build a *new* kernel - deleting them costs nothing but a re-download.

**Nothing existing is edited.** No Valve-shipped file is touched, and `grub.cfg` is byte-for-byte stock.

### The boot-safety design

The TV is this machine's only console, so a kernel that fails to modeset is a lockout. Three things make that survivable, and the third is the important one.

**1. The kernel lives in `/boot/frl/`, not `/boot/`.** GRUB's `10_linux` globs `/boot/vmlinuz-*` and is not recursive, so a subdirectory is invisible to it. The generated `grub.cfg` therefore never mentions this kernel at all, `GRUB_DEFAULT` stays at its stock `0`, and `update-grub` does not even need to run. The entire FRL boot path is **one file**: `custom.cfg`.

That gives the failure mode you want: if `custom.cfg` is missing or malformed - exactly what an A/B update does to the EFI partition - GRUB falls straight through to completely stock behaviour and boots the Valve kernel. There is no state in which a broken FRL install can stop the stock kernel booting.

An earlier version instead installed into `/boot/` and pinned `GRUB_DEFAULT` to the stock entry's id. That worked, but it made correct booting depend on a *correct* setting rather than on the absence of any setting. The subdirectory approach is strictly better.

**2. `GRUB_TIMEOUT` does nothing on SteamOS.** Valve's "steamenv header sub block" hardcodes `timeout=0` at line ~79 of the generated `grub.cfg` and ignores `/etc/default/grub*` entirely - so no menu ever appears and an alternate kernel is unreachable. The override has to run *later*. `/etc/grub.d/41_custom` sources `${config_directory}/custom.cfg` at line ~211, which is after it. That is why the timeout, the menu entry and `set default` all live in the same file.

**3. `dcfeaturemask` is on the FRL entry only.** Setting it via `GRUB_CMDLINE_LINUX` injects it into **every** entry, including the stock one. The first attempt did exactly that, caught by diffing the generated 6.16 command line against the live `/proc/cmdline`. It would have been harmless - 6.16's highest defined bit is `DC_REPLAY_MASK = (1 << 9)`, so bit 10 is undefined there - but "harmless" is not "unchanged", and the fallback kernel should be unchanged.

`set default` in `custom.cfg` is guarded by `[ -z "${boot_once}" ]`, so `grub-reboot` still works for a one-shot boot into a different entry.

**4. `set fallback` covers the one gap the above does not.** Everything so far protects against `custom.cfg` being *absent*. It does not protect against `custom.cfg` being present and pointing at a kernel that isn't - a partial install, an interrupted uninstall, a manual deletion. In that state GRUB prints an error and waits for a keypress *with no timeout*, which on a TV-only machine is an outage. So `custom.cfg` also sets:

```
set fallback="gnulinux-simple-<rootfs-uuid> 0"
```

By id first, since `10_linux` names the top-level SteamOS entry after the rootfs UUID; by index `0` as a backstop if a future `grub.cfg` drops the id. Any failure to load the FRL entry now boots the stock kernel automatically.

The uninstall path is ordered to match: the menu entry is removed *before* the kernel it points at, and the "is the stock kernel still in `grub.cfg`?" check runs before anything is deleted rather than after.

### Recovery

In order: let `set fallback` boot the stock kernel by itself → wait out the 10-second menu having selected the stock entry → power-cycle and pick it → ssh in → `sudo ./install.sh --uninstall` → `steamcl.efi` and the A/B slots are untouched throughout.

`--uninstall` refuses to run while the FRL kernel is the running kernel, and refuses to *start* if the stock kernel is missing from `grub.cfg`.

There is also a **fallback-initramfs entry** (`frl-probe-fallback`), which boots the same kernel with the no-autodetect image. The preset built that image either way; before this it was 20 MB that nothing could reach.

## Gaps

### CEC still does not work (M)

One of the two reasons for leaving the converter, and **the native port does not fix it**. The `cec` module is loaded and `drm_display_helper` and `amdgpu` both reference it, but **no CEC adapter is registered** and there is no `/dev/cec*` node.

The `hdmi_cec_state` debugfs entry reports `HDMI-CEC status: 1`, but that is the *sink's* advertised CEC capability read over DDC - not a Linux CEC adapter. amdgpu has never exposed one for its own HDMI ports; the `cec` dependency comes from `drm_display_helper`'s DisplayPort CEC-tunnelling path, which needs a DP branch device.

**Verdict: not closable in software.** There is no module to load, no parameter to set and no debugfs knob that registers an adapter; the capability does not exist in the driver. The options are:

- **A USB CEC adapter** (Pulse-Eight or similar) - `cec-gpio`/`usbcec` register a real adapter and `libcec` works. Costs a USB port and about $60 AUD. The only option that works today.
- **Wait for amdgpu to implement it.** No sign of it upstream. i915 and the DW-HDMI bridge drivers have CEC adapters; amdgpu does not.
- **HDMI-CEC over the TV's own eARC/SIMPLINK** for the subset of things the TV can do itself - does not give the machine control.

### VRR: solved (2026-08-06)

**Working.** `vrr_range` reads `Min: 40  Max: 120` and the `vrr_capable` DRM property on the connected HDMI-A-1 is `1`, at 3840x2160 @ 120 Hz over native FRL. Section 6 of [`frl-4k120-evidence.txt`](frl-4k120-evidence.txt) has the capture.

The rest of this section is kept because it is the diagnosis, and it explains why the fix is the four patches in [patches/](patches/) rather than anything configurable.

Stock 7.2-rc6 reads `Min: 0  Max: 0` with `vrr_capable` `0`. Expected: 7.2 shipped FRL **without** HDMI VRR, which is precisely why FRL is disabled by default there. Upstream commit `c3778921bf0d` says so in its own message.

Note this is not a regression - VRR did not work through the converter either, for a different reason (it did not pass FreeSync through at all; see [hardware/display/](../display/README.md)).

**The exact gate, traced in the 7.2-rc6 source.** `amdgpu_dm_update_freesync_caps()` (`amdgpu_dm.c:13884`) has three branches that can set `freesync_capable = true`: DP/eDP, `sink_signal == SIGNAL_TYPE_HDMI_TYPE_A`, and the PCON whitelist. FRL is a **distinct signal type** - `SIGNAL_TYPE_HDMI_FRL = (1 << 8)` against `SIGNAL_TYPE_HDMI_TYPE_A = (1 << 2)` in `signal_types.h:40,46` - and link detection sets it (`link_detection.c:855`). So it matches none of the three, `drm_connector_set_vrr_capable_property(connector, false)` is called, and userspace is never offered `VRR_ENABLED`.

Everything *downstream* is already fine. `optc401_set_drr()` and `optc401_set_vtotal_min_max()` contain no signal check at all; `dc->caps.max_v_total` is `(1 << 15) - 1` on Navi 48; the FreeSync SPD packet already reaches HPO generic slot 3 on the FRL encoder; slot 12 is wired for VTEM but nothing ever populates it. Dynamic vtotal is available on this path today - the driver just refuses to advertise it.

**There is a reviewed patch series for exactly this.** Fangzhi Zuo (AMD, the FRL author) posted four patches on **30 July 2026**, all Reviewed-by Harry Wentland the next day:

| Patch                                                                      | What it does                                                                                            |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| 1/4 `Add 2.1 FreeSync support for AMD VSDB EDID Block`                     | accepts `SIGNAL_TYPE_HDMI_FRL` when parsing the AMD VSDB, and emits the VTEM infopacket for FRL streams |
| 2/4 `drm/edid: parse HDMI 2.1 gaming (ALLM/VRR) capabilities from HF-VSDB` | DRM core - reads HF-VSDB bytes 8/9/10, which mainline drops on the floor today                          |
| 3/4 `Add HDMI 2.1 VRR support from HF-VSDB`                                | falls back to the HDMI Forum VRR range when the AMD VSDB has none                                       |
| 4/4 `Add HDMI ALLM support`                                                | ALLM in the HF-VSIF                                                                                     |

Not merged, and not in `amd-staging-drm-next` - but note *why*: that branch's tip is `d8ab7636160e`, dated **29 July**, one day before the series was posted, and it has not moved since. Its absence there was never evidence of anything. An earlier version of this section said "nothing to build"; it was grepping for Valve's identifiers (`allm_mode`, `hdmi_vrr_desktop_mode`, `freesync_pcon_allow_all`) rather than AMD's, and those belong to a different, TMDS/PCON-only implementation.

The thread mbox is fetchable from lore (Anubis blocks a plain `curl`; a git user-agent passes) and the patches apply by hand. 7.3 does not exist yet - 7.2 is still at rc6 - so this was a hand-applied in-review series or nothing. **Applied 2026-08-06**; see [patches/](patches/) for the ported series and what had to change to land it on mainline.

**Why patch 3/4 is the one that mattered here.** The C9's EDID has **no AMD VSDB at all** - no FreeSync block. Every pre-series kernel derived HDMI FreeSync capability solely from that block, so this TV could never report VRR, on FRL or through the converter. Its HDMI Forum VSDB does carry `VRRmin: 40 Hz`, `VRRmax: 120 Hz` and `Supports Auto Low-Latency Mode`, and 3/4 is exactly the fallback that reads them. Patch 1/4 alone would have done nothing on this display.

Confirmation that the timing generator followed: the DTN log's OTG row now shows `vmax 4500 vmin 4500` with `vmax_sel`/`vmin_sel` both `1`. Both selectors read `0` on every earlier kernel - dynamic vtotal was available the whole time and simply never armed.

Also worth taking regardless of VRR: `drm/amd/display: restore FRL cap on non-destructive HDMI link verify` (August archive), without which an FRL link can collapse back to TMDS across a hotplug.

### The probe kernel is mainline, so Valve's patches are gone (M)

Not currently causing a visible problem, but worth being explicit about. Running 7.2-rc6 means the machine has lost:

- `allm_mode`, `hdmi_vrr_desktop_mode`, `freesync_pcon_allow_all` - Valve's out-of-tree amdgpu parameters, all confirmed absent from mainline `amdgpu_drv.c`
- Whatever the `drm-exec` branch itself carries (unexamined - the tree is available now, so this is answerable)

Everything else in `config-neptune` is either Steam Deck / handheld hardware that does not exist on an AM5 desktop (Vangogh audio, `MFD_STEAMDECK`, `LTRF216A`, the Lenovo/Asus/Zotac/OneXPlayer/MSI HID drivers) or plain config flags that were carried across by seeding from Valve's config.

## Reported upstream

[ValveSoftware/SteamOS#2698](https://github.com/ValveSoftware/SteamOS/issues/2698) - "SteamOS doesn't support 4k 120hz via HDMI (AMD Radeon RX 9070 XT)". A follow-up comment is drafted at [steamos-issue-2698-followup.md](steamos-issue-2698-followup.md), turning it from a feature request into a scoped backport request: the measurements, the symbol-extraction proof, the exact 7.2 SHAs, and the argument that it costs Valve nothing to ship - upstream keeps FRL disabled by default, so carrying the code changes nothing for any existing user or Deck.

## Next steps

### 1. Rebase onto Valve's kernel rather than running mainline (H)

The end state is Valve's 6.18-drm-exec **plus** the FRL commits, so the machine keeps Valve's patches and gains FRL. All the pieces are already local:

- the Valve bare repo at tag `6.18.33-drmexec-valve2`
- `v7.2-rc6` fetched into the same repo, so the commits are directly cherry-pickable

The commits to take, all verified present in `v7.2-rc6` (`075b74841bd0`):

| SHA            | Subject                                                  |
| -------------- | -------------------------------------------------------- |
| `c3778921bf0d` | Disable FRL and add module param to enable it            |
| `443290d70b01` | Add AV mute wait frames to `dce110_set_avmute`           |
| `c216b39fbbc4` | Increase HDMI AV mute wait from 2 to 3 frames            |
| `fed376e1f2e3` | Fix kdoc parameter names for DSC padding helper          |
| `ee911514a9f8` | Rename `hdmi_frl_borrow_mode`                            |
| `5726af470517` | Widen FRL debug knobs to unsigned int                    |
| `1e13b7eb67f9` | Widen `dc_hdmi_frl_flags.force_frl_rate` to unsigned int |

Plus the 14-patch series itself and the ~9 register-header commits that were split out of it before merge (they landed separately on 2026-05-11 - a `git am` of the mailing-list v3 mbox will *not* compile without them, which is why cherry-picking merged SHAs is the right route).

The two AV-mute commits are `Cc: stable` and fix "garbled display after link re-establishment". That is worth having on a TV.

Expect real work: `dc/dml2` was renamed to `dc/dml2_0` in 6.19, and there are roughly 740 commits of DC churn between 6.18 and 7.2. Budget a day, not an afternoon.

### 2. Or just wait for 7.2 final, then for Valve (L)

7.2 final is due 16-30 Aug 2026. Valve are on 6.18 now, so a 7.2-based neptune kernel is likely months away, and they may well leave FRL disabled since upstream does.

### 3. Answer the open question about `drm-exec` (L)

The Valve tree is now local. `git log v6.18..6.18.33-drmexec-valve2` against a fetched upstream tag will list exactly what Valve add, which retires the "unexamined" caveat above.

### 4. Apply the four VRR patches - DONE 2026-08-06

Kept for the record. See the VRR section above for what they are and why they applied to this exact configuration, and [patches/](patches/) for the ported series. Result: `vrr_range Min: 40 Max: 120`, `vrr_capable 1`, with the link otherwise unchanged.

The thing to re-check periodically is whether they have been merged, since ours are hand-ported off an unmerged posting:

```bash
cd /home/deck/kernel-frl/build72
git fetch agd5f amd-staging-drm-next
git log --oneline FETCH_HEAD -i --grep='HF-VSDB' --grep='ALLM' -- drivers/gpu/drm
```

The thread mbox is already fetched. Note that `lore.kernel.org` is behind Anubis proof-of-work, so a plain `curl` gets a challenge page; a git user-agent passes:

```bash
curl -A 'git/2.5' -o series.mbox.gz \
  'https://lore.kernel.org/amd-gfx/20260730171754.704049-1-jerry.zuo@amd.com/t.mbox.gz'
```

Caveat: it is an unmerged series and patch 4/4 has an unaddressed review comment, so expect to hand-fix. Also re-check `amd-staging-drm-next` first - if it has moved past 29 July, the patches may have landed and a plain fetch is easier:

```bash
cd /home/deck/kernel-frl/build72
git fetch agd5f amd-staging-drm-next
git log --oneline FETCH_HEAD -i --grep='HF-VSDB' --grep='ALLM' -- drivers/gpu/drm
```

## How it survives updates

A SteamOS A/B update replaces the rootfs slot **and** the per-slot EFI partition, so the kernel, its modules, the mkinitcpio preset and `custom.cfg` are all destroyed. One thing survives, and it is enough: `/etc/systemd/system/*.service` is on Valve's default keep list (`/usr/lib/rauc/atomic-update-keep.conf`).

So the chain is:

1. Update lands. Machine boots the **stock Valve kernel** - the FRL entry no longer exists, and `grub.cfg` was never modified, so this needs nothing to go right.
2. `steam-machine-kernel.service` starts and runs `install.sh --boot`.
3. That restores the kernel and modules from the 172 MB tarball in `/home/deck/.cache/frl-kernel/`, regenerates the initramfs, and rewrites `custom.cfg` **with the new slot's rootfs UUID** - which matters, because an update can land you on the other A/B slot with a different UUID. A preserved copy of `custom.cfg` would have the wrong one, which is exactly why it is regenerated rather than allowlisted.
4. Next boot, the FRL entry is back and is the default again.

You lose the FRL kernel for exactly one boot after an update. Making that zero would mean writing to the *inactive* slot before the swap, which is far more machinery than the problem deserves.

`install.sh --boot` checks every component independently and exits in about 20 ms when they are all present, so it costs nothing on a normal boot. The unit is `Type=oneshot` with `SuccessExitStatus=0 1`, so a failure can never block boot - the machine is on the stock kernel at that point and is perfectly usable without this.

### After a SteamOS update

**Required steps: none.** The repair is automatic. What to expect, and how to confirm it worked:

1. **The first boot after the update is on the stock Valve kernel**, at 4K60. That is normal and unavoidable - the update destroyed the FRL kernel, and the repair runs *during* that boot. Do not go looking for a fault yet.
2. **Reboot once more.** The FRL entry is back and is the default again. If you are not in a hurry you can ignore this - the next normal reboot picks it up.
3. **Confirm:**
   ```bash
   sudo ~/git/steam-machine/hardware/kernel/install.sh --status
   ```
   Every line should read `yes`, `grub.cfg is stock : yes`, and the link state block should be present with `vrr_range : Min: 40 Max: 120`.

If step 2 does not bring it back, the self-heal did not run or did not finish. Check it, then run it by hand - it is idempotent and safe to repeat:

```bash
systemctl status steam-machine-kernel.service
journalctl -b -u steam-machine-kernel.service
sudo ~/git/steam-machine/hardware/kernel/install.sh --boot
```

Three things break the self-heal, all of them things *you* would have had to do:

- **Moving or deleting `~/git/steam-machine`.** The unit's `ExecStart` is an absolute path into it, guarded by `ConditionPathExists`, so the unit silently does nothing rather than failing loudly. Re-run `sudo ./install.sh --install` from the new location.
- **Deleting `~/.cache/frl-kernel/`.** That tarball *is* the kernel; nothing else on the machine has a copy. Without it you are rebuilding from [patches/](patches/).
- **A full rootfs.** The restore needs ~200 MB on `/`, which has under 800 MB free. `--boot` fails cleanly and leaves you on the stock kernel rather than half-installed.

**One thing worth checking after a *major* SteamOS release** (3.9, say), rather than a point update: whether Valve have shipped a kernel with native FRL themselves. If they have, all of this becomes unnecessary - `sudo ./install.sh --uninstall` and go back to stock.

```bash
# does the stock Valve kernel have the native FRL encoder yet?
k=$(ls /usr/lib/modules | rg neptune | head -1)
zstd -dc "/usr/lib/modules/$k/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst" \
  | strings | rg -c dcn401_hpo_frl_stream_encoder || echo 0
```

Non-zero means Valve now ship it.

### Tested by wiping each piece

Each of these was deleted and `--boot` run, then `--status` checked:

| Deleted               | Restored                                    |
| --------------------- | ------------------------------------------- |
| `custom.cfg`          | yes, with the correct rootfs UUID           |
| the mkinitcpio preset | yes                                         |
| both together         | yes                                         |
| nothing               | correctly a no-op - "intact, nothing to do" |

That found a real bug. `install_preset` was originally gated behind the initramfs check, so a run where only the preset had been deleted restored nothing while still reporting success. It is now split into `install_preset_file` and `regen_initramfs`, which is why they are separate functions.

A stale `custom.cfg` - right file, wrong rootfs UUID, which is what an A/B slot swap would leave behind if the file were ever preserved - is detected and rewritten. Tested by substituting an all-zero UUID: `--status` reports `STALE`, and `--boot` repairs it.

**`mkinitcpio` always exits 1 on this machine**, and that is expected: the SteamOS hooks ask for `steamdeck`, `steamdeck_hwmon`, `leds_steamdeck`, `extcon_steamdeck` and `blake2b_generic`, none of which exist in a mainline build. The running kernel booted from an image with exactly those errors. So the exit status alone cannot be the test - `regen_initramfs` filters those five known-benign lines, fails on any `ERROR` left over, and then requires both images to be *newer than the run*. The earlier version piped the output through `grep ... || true`, which discarded the exit status entirely and would have accepted a stale image from a previous kernel.

The full-wipe case - deleting `/usr/lib/modules/<kver>` and `/boot/frl` - was **not** run live, because the FRL kernel was the running kernel and pulling its modules out from under it is a genuinely bad idea. Instead the cache tarball was extracted to a temp directory and verified to contain the right payload: `vmlinuz` byte-identical to the installed one, all modules, both out-of-tree modules (`it87.ko`, `btusb_mt7902.ko`), and no dangling `build` symlink. That path will get its real test the first time an update actually lands.

### What is *not* worth persisting

The 40 GB source and build tree in `/home/deck/kernel-frl/`. The cache tarball is self-sufficient; the tree is only needed to build a *new* kernel, and is reproducible from the source package plus a `git fetch`.

## Useful commands

```bash
# which kernel, and is FRL enabled
uname -r; cat /sys/module/amdgpu/parameters/dcfeaturemask   # 1026 == 0x402

# is the native FRL path actually running (empty on any Valve kernel)
sudo dmesg | grep hdmi_frl_status_polling

# link state: lanes, pixel format, bit depth, ODM segments
sudo grep -A2 '^HPO:' /sys/kernel/debug/dri/0/amdgpu_dm_dtn_log

# underflow and per-pipe surface format (8h = ARGB8888, 18h = FP16/HDR)
sudo grep -A4 '^HUBP:  format' /sys/kernel/debug/dri/0/amdgpu_dm_dtn_log

# is DSC in use (CLOCK_EN 0 means no)
sudo grep -A3 '^DSC:' /sys/kernel/debug/dri/0/amdgpu_dm_dtn_log

# HDR: 0 = SDR desktop, 9 = BT2020_RGB
sudo drm_info | grep -A1 Colorspace

# the gaps
sudo cat /sys/kernel/debug/dri/0/HDMI-A-1/vrr_range      # Min: 0 Max: 0
ls /dev/cec*                                             # none

# regenerate the evidence capture
sudo cat hardware/kernel/frl-4k120-evidence.txt
```

## Warning

**This is not a supported configuration and comes with no warranty of any kind.** It replaces the kernel and adds a bootloader config on a device Valve ship as an appliance. It has worked reliably here since 2026-08-06, on one machine, with one GPU and one TV. If it breaks yours, you keep both pieces.

Specifically, be aware that:

- **The VRR patches are unmerged.** `0002`-`0005` are a public mailing-list posting, reviewed but not accepted, hand-ported to a tree they were not written against. They may change or be rejected upstream.
- **7.2-rc6 is a release candidate.** It gets no stable or CVE fixes. Rebuild at 7.2 final.
- **You lose Valve's kernel patches** while running it. See [the gap](#the-probe-kernel-is-mainline-so-valves-patches-are-gone-m) for what that costs on a desktop.
- **A SteamOS update leaves you on the stock kernel for one boot.** Expected, not a fault - see [After a SteamOS update](#after-a-steamos-update).

The design assumes the display is the machine's only console, so a failed modeset would otherwise be a lockout. Three things make that survivable, and `install.sh` sets all of them up: `grub.cfg` is never modified, the whole FRL boot path is one file that GRUB simply skips if absent, and `set fallback` boots the stock Valve kernel automatically if the FRL entry cannot load. Before rebooting into any newly built kernel, confirm `sudo ./install.sh --status` reports `grub.cfg is stock : yes`. See the same warning in [hardware/display/](../display/README.md).
