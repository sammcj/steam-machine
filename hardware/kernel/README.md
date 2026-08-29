# Kernel - HDMI 2.1 FRL for 4K120 and VRR on the native HDMI port

## Status: working, persistent, and the default boot entry

**4K 120 Hz, RGB 4:4:4, 12 bpc, uncompressed, HDR10, zero underflow - over the GPU's native HDMI port**, on a hand-built mainline kernel. Achieved 2026-08-06. The UGREEN DP→HDMI converter is out of the chain entirely.

> **Kernel version.** The machine runs **Linux 7.2.2**, release string `7.2.2-frlprobe`, built from `/home/deck/kernel-frl/build72`. The work up to 2026-08-08 was done on **7.2-rc6** (`7.2.0-rc6-frlprobe`), rebased onto **7.2 final** on 21 August (`7.2.0-frlprobe`) and onto **7.2.2** on 29 August. The measurements below were taken on rc6 and neither rebase changed the result. Where an rc6 detail is load-bearing - a source line number, a measurement, a thing checked at the time - it is still named as rc6 on purpose.
>
> **Stable point releases are not in Linus's tree.** `git fetch torvalds tag v7.2.2` fails with `couldn't find remote ref` - 7.2.x lives in the *stable* tree, and the repo needs a second remote for it:
>
> ```bash
> git remote add stable https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
> git fetch --no-tags stable tag v7.2.2
> ```
>
> The fetch is incremental on top of an existing mainline clone (7.2.2 is two commits past `v7.2`), so it costs seconds, not another 3.7 GB.

This is strictly better than what the converter delivered on picture quality: it managed 10 bpc *with* DSC, plus intermittent glitching. CEC was never tested while it was in the chain, and on the evidence below it may well have worked - see [CEC still does not work](#cec-still-does-not-work-m). See [hardware/display/](../display/README.md) for that setup, which this replaces.

Full measurement capture, with the raw debugfs output it was read from: [`frl-4k120-evidence.txt`](frl-4k120-evidence.txt).

**HDMI VRR and ALLM work too**, since 2026-08-06 - `vrr_capable 1`, and the timing generator armed across the full 40-120 Hz range - via AMD's unmerged 4-patch series ported onto this build. See [patches/](patches/). Everything measured is source-side; the TV has not been asked to confirm it.

**It survives SteamOS updates** (since 2026-08-06), via a cached artefact tarball under `/home` and a keep-listed systemd unit that reinstalls whatever an A/B update deleted. It is also the **default boot entry**, with a 10-second menu to pick the stock Valve kernel instead. See [Install](#install) and [How it survives updates](#how-it-survives-updates).

> **Fixed 2026-08-08: the machine would not power off.** Eight hangs over three days, from a kernel that otherwise worked perfectly. Two independent causes, each of which had to be removed before the machine would reach S5: `mt7921e` binding an MT7902 whose Wi-Fi firmware does not exist, and the Gamescope session holding the GPU as shutdown began. See [SOLVED: power-off hangs](#solved-power-off-hangs-2026-08-06-to-2026-08-08).

## TL;DR

Everything below this section is the reasoning. If you just want it working:

> **No warranty.** This replaces your kernel and edits your bootloader config on hardware that is not mine; it worked here, it may not work for you, and you run it entirely at your own risk. Read [Warning](#warning) before starting.

**You need this if** you have an RDNA4 Radeon (RX 9000 series) on SteamOS, a HDMI 2.1 display, and the HDMI port refuses anything above 4K60. No Valve kernel has native FRL, so no setting fixes it - it needs a different kernel.

**Before you start:** clone this repo somewhere permanent under `/home` and leave it there. `install.sh` registers a systemd unit pointing at an absolute path into it, and that unit is what puts the kernel back after a SteamOS update. Moving the repo later means re-running `--install`.

All commands below are run from `hardware/kernel/` in this repo.

1. **Get the sources** - Valve's kernel source package (for its config), plus `v7.2.2` fetched into the same git repo from the **stable** remote, not `torvalds`. [Commands](#1-get-valves-source-tree).
2. **Apply the patches** - all five, in order, are in [patches/](patches/):
   ```bash
   cd /home/deck/kernel-frl/build72
   git checkout -b frl v7.2.2
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
5. **Install what you built** - modules, kernel, initramfs, boot entry and self-heal service, straight from the build tree:
   ```bash
   sudo ./install.sh --install-build   # finds stage*/lib/modules/<kver> next to the build tree
   ```
   Note what this does *not* do: it does not touch the cache. **Boot it first, then cache it** - `--cache` snapshots what is installed, so caching a kernel you have not booted stores an untested one and schedules it to deploy itself at the next OS update. That is exactly how this machine lost its kernel on 2026-08-28; see [The cache is the kernel](#the-cache-is-the-kernel-and-it-can-drift-silently).
6. **Reboot.** A 10-second menu appears with the FRL entry preselected. The stock Valve kernel is one arrow-key up, and GRUB falls back to it automatically if the FRL entry cannot load - so a bad build costs you a reboot, not a lockout. That safety is built into `install.sh`; you do not configure it.
7. **Check it, then cache it:**
   ```bash
   sudo ./install.sh --status
   sudo ./install.sh --cache     # only now: pack the kernel you have just proven boots
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

Everything the kernel carries on top of stock mainline is in [patches/](patches/) as `git format-patch` output, with provenance for each. Applying them in order onto a clean `v7.2.2` reproduces the running kernel:

```bash
git checkout -b frl-rebuild v7.2.2
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
git fetch --no-tags torvalds tag v7.2
git worktree add ../../build72 v7.2

# Stable point releases (7.2.1, 7.2.2, ...) are NOT in Linus's tree -- fetching
# them from `torvalds` fails with `couldn't find remote ref refs/tags/v7.2.2`.
# They need the stable tree, which shares the same history so the fetch is
# incremental:
git remote add stable https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
git fetch --no-tags stable tag v7.2.2
```

### 2. Restore the Valve colour properties

Gamescope offloads HDR colour management onto DCN hardware via AMD's driver-private per-plane properties (`AMD_PLANE_CTM`, `BLEND_TF`, `SHAPER_LUT`, `LUT3D`, `HDR_MULT`, ...). SteamOS enables them with `CONFIG_DRM_AMD_COLOR_STEAMDECK=y`, which does not exist upstream.

This needs no backport. **All of the code is already in mainline** - in `amdgpu_dm_color.c`, `amdgpu_dm_crtc.c` and `amdgpu_dm_plane.c` - guarded by `#ifdef AMD_PRIVATE_COLOR`, a bare define mainline never sets. Upstream's own documentation in `amdgpu_dm_color.c` says the properties are exposed "when the kernel is built explicitly with `-DAMD_PRIVATE_COLOR`".

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

`it87` (sensors) and `btusb_mt7902` (Bluetooth) must be rebuilt per-kernel or the probe boot loses fan/temp readings and Bluetooth. Both build cleanly against 7.2:

```bash
# in the container, against /work/build72
make -C /work/build72 M=$PWD modules                       # it87
make KVER=7.2.2-frlprobe KSRC=/work/build72                # btusb_mt7902
```

Install into `/usr/lib/modules/<kver>/updates/` and `depmod`, matching where [hardware/sensors/](../sensors/README.md) and [hardware/bluetooth/](../bluetooth/README.md) put them.

## Install

```bash
sudo ./install.sh --install-build  # install a freshly built kernel from the build tree
sudo ./install.sh --cache          # snapshot the INSTALLED kernel + modules into /home
sudo ./install.sh                  # deploy from the cache and make it the default boot entry
sudo ./install.sh --status         # what is installed, the live FRL link state, cache freshness
sudo ./install.sh --uninstall      # remove everything, back to stock
```

The order matters and it is **build → `--install-build` → reboot → `--cache`**. `--cache` snapshots the **installed** kernel image at `/boot/frl/vmlinuz-linux-frlprobe` together with the **installed** module tree at `/usr/lib/modules/<kver>`, and writes a **172 MB** tarball to `/home/deck/.cache/frl-kernel/`. It reads the version out of the bzImage header rather than trusting a path, and warns when the build tree at `/home/deck/kernel-frl/build72` (override with `FRL_BUILD_TREE`) holds a different kernel from the installed one.

It did not always do that: until 2026-08-28 it took the image from the build tree and the modules from `/usr/lib/modules`, which let a rebuild that was never installed get packed next to the previous build's modules. Same release string, so nothing could tell - until the restore after an OS update hung at the boot splash.

That tarball is the only part of this that survives a SteamOS A/B update - `/boot` and `/usr/lib/modules` are both wiped, and `--boot` restores them from it. So **anything you add to the installed module tree is lost at the next OS update unless you re-run `--cache`**. Adding or rebuilding a module (`hid-steam`, `it87`, `btusb_mt7902`) means re-running it. `--status` compares the two and prints `cache freshness: STALE` with the offending files when they have drifted.

### What lands on the machine

| Path                                                  | What                                            | Survives an update?      |
| ----------------------------------------------------- | ----------------------------------------------- | ------------------------ |
| `/boot/frl/vmlinuz-linux-frlprobe`                    | the kernel                                      | no - restored from cache |
| `/boot/frl/initramfs-linux-frlprobe{,-fallback}.img`  | generated by mkinitcpio                         | no - regenerated         |
| `/usr/lib/modules/7.2.2-frlprobe/`                    | modules, incl. `updates/{it87,btusb_mt7902}.ko` | no - restored from cache |
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

By id first, since `10_linux` names the top-level SteamOS entry after the rootfs UUID; by index `0` as a backstop if a future `grub.cfg` drops the id.

**5. `set default` is guarded by a probe, because `set fallback` was not enough.** Point 4 was tested by deleting the kernel and it worked - but it does not cover the case that actually happened on 2026-08-28. A SteamOS update landed the machine on the other A/B slot, `custom.cfg` survived with the *previous* slot's rootfs UUID, and the `fallback` id is built from that same stale UUID. So `search` found no device, the entry could not load its kernel, the fallback entry did not exist either, and GRUB stopped at *"Failed to boot both default and fallback entries. Press any key to continue"* - the exact outage point 4 exists to prevent.

The fix is to not claim the default unless the entry can actually work:

```
set frlroot=
search --no-floppy --fs-uuid --set=frlroot <rootfs-uuid>
if [ -n "${frlroot}" ]; then
  if [ -s ($frlroot)/boot/frl/vmlinuz-linux-frlprobe ]; then
    if [ -s ($frlroot)/boot/frl/initramfs-linux-frlprobe.img ]; then
      if [ -z "${boot_once}" ]; then
        set default="frl-probe"
      fi
    fi
  fi
fi
```

`-s` rather than `-e`: an interrupted install - a rootfs that went read-only mid-extraction, a full `/boot` - leaves a truncated or zero-length image, which `-e` accepts. A stale or half-installed FRL install now boots stock SteamOS silently, with the menu still there to pick the FRL entry by hand, and the next boot's self-heal repairs it. `fallback` stays as a second line of defence, but nothing depends on it any more.

The uninstall path is ordered to match: the menu entry is removed *before* the kernel it points at, and the "is the stock kernel still in `grub.cfg`?" check runs before anything is deleted rather than after.

### Recovery

In order: let `set fallback` boot the stock kernel by itself → wait out the 10-second menu having selected the stock entry → power-cycle and pick it → ssh in → `sudo ./install.sh --uninstall` → `steamcl.efi` and the A/B slots are untouched throughout.

`--uninstall` refuses to run while the FRL kernel is the running kernel, and refuses to *start* if the stock kernel is missing from `grub.cfg`.

There is also a **fallback-initramfs entry** (`frl-probe-fallback`), which boots the same kernel from the second image the preset builds. On SteamOS that image is a byte-identical *copy* of the default one, not the usual all-modules superset: `fallback_options="-S autodetect"` skips a hook that is not in HOOKS to begin with, because `/etc/mkinitcpio.conf.d/20-steamdeck.conf` replaces the list and omits `autodetect`. So it is insurance against a corrupted or truncated image, not against a missing module. The preset built it either way; before this entry existed it was 20 MB that nothing could reach.

## Gaps

### CEC still does not work (M)

One of the two reasons for leaving the converter, and **the native port does not fix it**. The `cec` module is loaded and `drm_display_helper` and `amdgpu` both reference it, but **no CEC adapter is registered** and there is no `/dev/cec*` node.

The `hdmi_cec_state` debugfs entry reports `HDMI-CEC status: 1`, but that is the *sink's* advertised CEC capability read over DDC - not a Linux CEC adapter.

#### Proof, from the module's own symbol table

The claim "amdgpu has no CEC adapter" is checkable in one command. Every CEC symbol `amdgpu.ko` imports falls into exactly two groups, and neither one creates an adapter:

```console
$ nm -u amdgpu.ko | rg -i cec
                 U cec_fill_conn_info_from_drm
                 U cec_notifier_conn_register
                 U cec_notifier_conn_unregister
                 U cec_notifier_set_phys_addr
                 U drm_dp_cec_attach
                 U drm_dp_cec_irq
                 U drm_dp_cec_register_connector
                 U drm_dp_cec_unregister_connector
                 U drm_dp_cec_unset_edid
```

- `cec_notifier_*` **publishes** the HDMI physical address parsed out of the EDID so that a *separate* CEC adapter driver - an SoC IP block, or a chip like `ch7322` - knows which address to claim. It allocates nothing. This is exactly what the [CEC core docs](https://docs.kernel.org/driver-api/media/cec-core.html) describe it for.
- `drm_dp_cec_*` is **CEC-Tunnelling-over-AUX** (added to amdgpu in 2018): CEC messages ride the DisplayPort AUX channel to a DP→HDMI branch device that implements CEC itself and advertises it in DPCD.

What is *absent* is the whole adapter-registration API - `cec_allocate_adapter`, `cec_register_adapter`, and Maxime Ripard's newer `drmm_connector_hdmi_cec_adapter_register`. That last one is merged upstream, but its only consumers are **vc4** (Raspberry Pi) and the **adv7511** bridge - SoC HDMI transmitters with a physically wired CEC line. No amdgpu, i915/xe or nouveau use of it.

Note that `drm_display_helper.ko` *does* import `cec_allocate_adapter` and `cec_register_adapter` - the adapter machinery is present and one DPCD capability bit away from running. It is `drm_dp_cec.c` that calls it, gated at `drm_dp_cec_cap()` on `DP_CEC_TUNNELING_CAPABLE` in the branch device's DPCD. There is simply no HDMI path into it.

#### And the silicon has no CEC controller either

The driver-side answer invites the obvious follow-up: is amdgpu just neglecting hardware that exists? Checked against AMD's own register headers in the 7.2-rc6 tree:

| Where | CEC content |
| --- | --- |
| `include/asic_reg/dcn/` (DCN 1.0 → 4.1.0) | **none** - zero macros containing `CEC`, any generation |
| `include/asic_reg/dce/` (DCE 6 → 11.2) | one bit: `DC_PINSTRAPS__DC_PINSTRAPS_BIF_CEC_DIS` |
| `display/dc/` (the layer that touches registers) | **none** |
| `display/dmub/inc/dmub_cmd.h` | **none** - no CEC command in the DMUB enum |
| `drivers/gpu/drm/radeon/` | **none** |

That single DCE bit is a read-only pinstrap reporting whether a *board-level* CEC function is strapped off, sitting next to `DC_PINSTRAPS_AUDIO` and `DC_PINSTRAPS_CONNECTIVITY`. It is not a controller: no TX or RX buffer, no logical-address register, no status or interrupt register, no clock divider. **No `.c` file in the kernel reads it.**

So there is no "DCE had CEC and DCN dropped it" story - it was never in the DCE headers either. There is no register block to program and no firmware command to send.

What amdgpu *does* have is `amdgpu_dm_initialize_hdmi_connector()` (`amdgpu_dm.c:9531`), called for `DRM_MODE_CONNECTOR_HDMIA`/`HDMIB` only, whose entire job is `cec_notifier_conn_register()` plus `cec_notifier_set_phys_addr()` on hotplug and `phys_addr_invalidate()` on unplug or suspend. It publishes an address for someone else's adapter and transmits nothing. `hdmi_cec_state` in debugfs (`amdgpu_dm_debugfs.c:2937`) prints only whether that notifier pointer is non-NULL - which is why it reads `1` on a machine with no CEC at all.

#### What is *not* established

The physical CEC pin (HDMI pin 13) may or may not be routed to anything on this card or board. No AMD statement, schematic or teardown was found either way, and the SMBus scan here found no CEC controller at the `ch7322` (`0x75`) or `tda9950` (`0x34`) addresses. That question is unresolved - and moot, because with no controller in the ASIC there is nothing to drive a wired pin.

This claim would be falsified by anyone producing `cec-ctl -d /dev/cec0 -S` output from a machine with a confirmed native-HDMI connection and no USB dongle or DP adapter in the chain. No such report exists in the amd-gfx archives, freedesktop GitLab, or the usual forums. Nvidia is on the record with the same answer for their own hardware - an Nvidia employee on their developer forum (Aug 2022) said HDMI-CEC "is not going to be implemented at this moment as it needs **hardware changes on the board**". The CEC pin is optional in the HDMI spec, and no AIB partner advertises it.

**Verdict: not closable in software on the native HDMI port.** No module, parameter or debugfs knob registers an adapter, because the capability is not in the driver. The options:

- **A DP→HDMI adapter that does CEC tunnelling**, on one of the spare DisplayPort outputs. This is the interesting one and it is untested here - see below.
- **A USB CEC adapter** (Pulse-Eight or similar) - registers a real adapter and `libcec` works. Costs a USB port and about $60 AUD.
- **Wait for amdgpu to implement it.** No sign of it upstream.
- **HDMI-CEC over the TV's own eARC/SIMPLINK** for the subset of things the TV can do itself - does not give the machine control.

#### "But CEC works on my 9070 XT" - what those reports actually are

They are the DP-AUX tunnel, not the HDMI port. The clearest evidence is [Twsts/steamos-cec-toolkit](https://github.com/Twsts/steamos-cec-toolkit), a SteamOS CEC toolkit whose **reference hardware is a Radeon 9070 XT with a UGREEN DisplayPort-to-HDMI CEC adapter** - the same class of device this build removed to get FRL. It requires `/dev/cec0` to already exist via that adapter; it does not claim GPU-native CEC. No first-hand report of `/dev/cec0` appearing from a Radeon's own HDMI connector turned up anywhere.

The other thing routinely misread is [Phoronix's 2018 write-up](https://www.phoronix.com/news/AMDGPU-Nouveau-CEC-Tunnel), quoted as "AMD has CEC support now". Its actual sentence is "AMDGPU and Radeon can now handle passing CEC commands **when using these DP/USB-C to HDMI adapters**". That is the tunnel, and it is the sentence being dropped.

Worth ruling out before believing any report: a USB CEC dongle elsewhere in the machine, an AVR doing the switching, the TV controlling *other* devices over its own bus, or ARC/eARC being mistaken for CEC. The one question that resolves nearly all of them is "is there anything in a DisplayPort output, or a USB port?".

**A real counter-example, and why it does not apply.** ChromeOS's `cros-ec-cec` driver exposes working CEC on machines with AMD graphics - but it is the mainboard's embedded controller driving the pin over its own GPIO, entirely independent of the GPU. Same category as a USB dongle, just soldered down. It proves the pin *can* be routed and driven when a vendor chooses to; it is not GPU-native CEC and there is no such EC on this board. The open, unresolved [Framework Desktop feature request](https://github.com/FrameworkComputer/SoftwareFirmwareIssueTracker/issues/129) for CEC on an AMD Ryzen AI 300 board is the same story from the other side.

#### What CEC would actually buy on this TV

Worth being concrete, because "the display wakes up when the PC boots" is true of monitors and **not** of this TV, and the two get conflated. A DP or HDMI monitor follows the signal - hot-plug detect plus auto-source-select, no messages sent, no CEC anywhere (CEC is not in the DisplayPort spec at all). An LG C9 is a consumer-electronics device that expects a CEC `Image View On` to leave standby.

Checked against LG's documentation for the C9 (webOS 4.5), with SIMPLINK off:

| Behaviour | Needs CEC |
| --- | --- |
| Wake from standby when the PC starts driving HDMI | **Yes.** LG documents only two ways the set powers itself on - the Power-On Timer, and CEC. There is no signal-only wake path |
| Auto-switch to an input that has become active | **Yes** - that is "Auto Device Detection", layered on SIMPLINK |
| Standby when the signal disappears | **No** - inactivity/no-signal timeout, independent of SIMPLINK |
| Power the TV off when the PC shuts down | **Yes** |
| Volume to the TV or AVR, magic remote driving Game Mode | **Yes** |

This is confirmed behaviour on this machine, not theory: with the PC up and driving HDMI at 4K120, the TV stays in standby until switched on by hand.

So the gap is real rather than cosmetic, which is what makes the DP-adapter idea below worth testing rather than filing as a curiosity.

#### Untested idea: CEC on a spare DP output, keeping HDMI for video

The TV has four HDMI inputs and the card has spare DisplayPort outputs. A DP→HDMI adapter with CEC tunnelling, plugged into an *unused* TV input, should register `/dev/cec0` and put the machine on the TV's CEC bus - while 4K120 FRL keeps running over the native HDMI port on the input the TV is actually displaying. CEC is a bus, not a per-input channel, so control should work regardless of which input is selected.

Worth trying with the UGREEN 80397 already in the parts bin, since it costs nothing: plug it into a spare TV input and check for `/dev/cec0`. Unknowns: whether that specific model implements CEC tunnelling at all (the toolkit's model is not identified), and whether the TV reacts badly to a second source it is not showing. The toolkit itself was removed on 2026-08-08 (see the root README), so this would mean reinstalling it — worth doing only once an adapter has actually produced a `/dev/cec0`.

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

Not merged, and not in `amd-staging-drm-next` - but note *why*: that branch's tip is `d8ab7636160e`, dated **29 July**, one day before the series was posted, and it has not moved since. Its absence there is not evidence of anything.

Two traps when searching for this work: check the branch's tip date before reading an absence as a decision, and grep for **AMD's** identifiers rather than Valve's. `allm_mode`, `hdmi_vrr_desktop_mode` and `freesync_pcon_allow_all` belong to a different, TMDS/PCON-only implementation and finding none of them says nothing about the FRL path.

The thread mbox is fetchable from lore (Anubis blocks a plain `curl`; a git user-agent passes) and the patches apply by hand. At the time 7.2 was still at rc6 and 7.3 did not exist, so this was a hand-applied in-review series or nothing. **Applied 2026-08-06**; see [patches/](patches/) for the ported series and what had to change to land it on mainline.

**Why patch 3/4 is the one that mattered here.** The C9's EDID has **no AMD VSDB at all** - no FreeSync block. Every pre-series kernel derived HDMI FreeSync capability solely from that block, so this TV could never report VRR, on FRL or through the converter. Its HDMI Forum VSDB does carry `VRRmin: 40 Hz`, `VRRmax: 120 Hz` and `Supports Auto Low-Latency Mode`, and 3/4 is exactly the fallback that reads them. Patch 1/4 alone would have done nothing on this display.

Confirmation that the timing generator followed, and that it is genuinely *variable* rather than merely enabled. `vmax_sel`/`vmin_sel` read `0` on every earlier kernel — dynamic vtotal was reachable on the FRL path the whole time and simply never armed. They now read `1`, and the bounds move with what the compositor asks for:

```
OTG:  ... vmax  vmin  vmax_sel  vmin_sel  ...  htot  vtot ...
[0]:  ... 6749  2249         1         1  ...  4399  2249     <- VRR active
[0]:  ... 4499  4499         1         1  ...  4399  2249     <- fixed 60 Hz
```

The registers store total-1, so `vmax 6749` is a vtotal of 6750. At the fixed 1188.00 MHz pixel clock and `htotal` 4400 that is `1188000000 / (4400 x 6750)` = **40.00 Hz**, and `vmin 2249` → 2250 → **120.00 Hz**. The hardware is armed over exactly the 40–120 Hz window the C9's HF-VSDB advertises. The second row is the same driver state clamped to one rate (`VRR_STATE_ACTIVE_FIXED`, both bounds at 4500 = 60.00 Hz), which is what a static desktop settles into — reading only that row would understate what is going on.

What this does *not* prove is the sink side: nothing here confirms the C9 is tracking the varying rate rather than ignoring it, and `content type 4` for ALLM is a source-side property, not proof the TV switched to game mode. The TV's own **Instant Game Response** indicator is the check that would close both, and it has not been done.

### Keeping FRL across a hotplug

`drm/amd/display: restore FRL cap on non-destructive HDMI link verify` — **applied as patch `0006`.** Also Fangzhi Zuo's, also Reviewed-by Harry Wentland, and since picked into Tom Chung's "DC Patches Aug 10 2026" as 31/34, so it is on the merge path and can be dropped at the next rebase.

It is one line, and it matters more here than upstream framing suggests. `verify_link_capability_non_destructive()` assigned the *DP* `verified_link_cap` on the HDMI branch and left `frl_verified_link_cap` stale, so `frl_link_rate` read back as `HDMI_FRL_LINK_RATE_DISABLE` and the stream collapsed to TMDS:

```c
	} else if (dc_is_hdmi_signal(link->local_sink->sink_signal)) {
-		link->verified_link_cap = link->reported_link_cap;
+		link->frl_verified_link_cap = link->frl_reported_link_cap;
```

Switching a TV off and on is a routine HPD event on a living-room machine, so this is a path that gets exercised daily here. And because `amdgpu_dm_update_freesync_caps()` keys on `SIGNAL_TYPE_HDMI_FRL`, a collapse to `SIGNAL_TYPE_HDMI_TYPE_A` silently takes **VRR** with it — the symptom is a drop to 4K60 with no error logged anywhere and `--status` still reporting everything installed.

### The probe kernel is mainline, so Valve's patches are gone (M)

Not currently causing a visible problem, but worth being explicit about. Running mainline rather than Valve's tree means the machine has lost:

- `allm_mode`, `hdmi_vrr_desktop_mode`, `freesync_pcon_allow_all` - Valve's out-of-tree amdgpu parameters, all confirmed absent from mainline `amdgpu_drv.c`
- ~~**`hid-steam` IDs for the 2026 Steam Controller.**~~ **Closed 2026-08-10.** Mainline carries none of Valve's `1302`/`1303`/`1304`/`1305` IDs, so the puck fell through to `hid-generic`; Valve's `hid-steam.c` from `6.18.42-valve2` compiles unmodified against 7.2 and is now carried as patches `0007`-`0008`. See [patches/](patches/) and [hardware/controller/](../controller/README.md)
- Whatever the `drm-exec` branch itself carries (unexamined - the tree is available now, so this is answerable)

Everything else in `config-neptune` is either Steam Deck / handheld hardware that does not exist on an AM5 desktop (Vangogh audio, `MFD_STEAMDECK`, `LTRF216A`, the Lenovo/Asus/Zotac/OneXPlayer/MSI HID drivers) or plain config flags that were carried across by seeding from Valve's config.

## Reported upstream

[ValveSoftware/SteamOS#2698](https://github.com/ValveSoftware/SteamOS/issues/2698) - "SteamOS doesn't support 4k 120hz via HDMI (AMD Radeon RX 9070 XT)". A follow-up comment is drafted at [steamos-issue-2698-followup.md](steamos-issue-2698-followup.md), turning it from a feature request into a scoped backport request: the measurements, the symbol-extraction proof, the exact 7.2 SHAs, and the argument that it costs Valve nothing to ship - upstream keeps FRL disabled by default, so carrying the code changes nothing for any existing user or Deck.

## Next steps

### 1. Rebase onto Valve's kernel rather than running mainline (H)

The end state is Valve's 6.18-drm-exec **plus** the FRL commits, so the machine keeps Valve's patches and gains FRL. All the pieces are already local:

- the Valve bare repo at tag `6.18.33-drmexec-valve2`
- `v7.2` fetched into the same repo, so the commits are directly cherry-pickable

The commits to take, all verified present in `v7.2-rc6` (`075b74841bd0`) and therefore in `v7.2`:

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

### 2. Or just wait for 7.2 final, then for Valve - DONE for 7.2, still waiting on Valve (L)

7.2 final landed 17 Aug 2026 and this build rebased onto it on 21 August, then onto **7.2.2** on 29 August. Valve are still on 6.18, so a 7.2-based neptune kernel is likely months away, and they may well leave FRL disabled since upstream does. Nothing to wait for on the mainline side any more - see [Rebasing onto a new stable release](#rebasing-onto-a-new-stable-release).

### Rebasing onto a new stable release

Done for 7.2 → 7.2.2 on 2026-08-29. About 40 minutes end to end, most of it the ~25 minute compile. The whole procedure:

```bash
cd /home/deck/kernel-frl/build72

# 1. Fetch the tag. Stable point releases are NOT in Linus's tree -- see the
#    note at the top of this file.
git remote add stable https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git   # once
git fetch --no-tags stable tag v7.2.2

# 2. New branch at the tag, patches on top. Keep the old branch: it is the only
#    record of exactly what the previous kernel was.
git checkout -B frl-722 v7.2.2
git am /home/deck/git/steam-machine/hardware/kernel/patches/*.patch

# 3. Reuse the existing .config -- it is untracked, so the checkout leaves it
#    alone, and re-seeding from Valve's would discard any answer given since.
cd /home/deck/kernel-frl
podman run --rm -v $PWD:/work -w /work/build72 localhost/kbuild:arch make olddefconfig
podman run --rm -v $PWD:/work -w /work/build72 localhost/kbuild:arch make -j$(nproc) all
podman run --rm -v $PWD:/work -w /work/build72 localhost/kbuild:arch \
  make -j$(nproc) modules_install INSTALL_MOD_PATH=/work/stage722 INSTALL_MOD_STRIP=1

# 4. Out-of-tree modules against the new KVER, then install, boot, and only
#    then cache.
```

**Before starting, read the changelogs rather than assuming the patches still apply.** For 7.2.1 and 7.2.2, grepping both for `amdgpu`, `drm/amd`, `hid-steam` and `mt76` returned nothing, so none of the eight patches could have been upstreamed or conflicted - and none were. 7.2.1 is 83 fixes (Bluetooth core, HID, NFC, io_uring, futex, filesystems); 7.2.2 is a single one, `inet: frags: strip GSO state from fragments before reassembly`, an unprivileged local panic in `skb_segment()`. Nothing display-, GPU- or shutdown-related in either, so **a stable bump was never going to fix the power-off hang** - the `mt7921e` blacklist and the shutdown VT switch are both still required.

**A stable bump changes the release string**, which is the one way it differs from an ordinary rebuild: `7.2.0-frlprobe` → `7.2.2-frlprobe`. The new modules land in a new `/usr/lib/modules` directory and the old tree is left intact, so a rollback has something to roll back to. `/boot/frl/vmlinuz-linux-frlprobe` is still overwritten in place - the boot filenames carry no version - so take the artefact backup anyway.

Nothing in `install.sh` needs editing for a version bump: `kver_of_image()` reads the version out of the bzImage header and `--install-build` discovers `stage*/lib/modules/<kver>` next to the build tree.

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

`install.sh --boot` checks every component independently and exits in about 20 ms when they are all present, so it costs nothing on a normal boot. The unit is `Type=oneshot` and nothing it does can block boot - the machine is on the stock kernel at that point and is perfectly usable without this. A failure is left visible in `systemctl status` on purpose; there is no `SuccessExitStatus` override to paper over it.

**Step 3 has to serialise against every other subsystem's self-heal.** All thirteen `install.sh --boot` units are wanted by `multi-user.target`, so systemd starts them in the same second, and several of them unlock the rootfs, write to `/usr`, and relock on the way out. `steamos-readonly` is one piece of global state with no ownership, and on 2026-08-28 that cost the kernel exactly what this section promises:

```
17:51:28  kernel   `steamos-readonly status` -> disabled (a sibling had already unlocked),
                   so it unlocked nothing itself and began extracting.
17:51:28  sibling  finished, ran `steamos-readonly enable`.
17:51:28  kernel   tar: usr/lib/modules/...: Cannot mkdir: Read-only file system
```

The restore died mid-`tar` with a `vmlinuz` in place and no modules, no initramfs, and `custom.cfg` never reached - which is how the stale-UUID boot entry above survived to be booted. `unlock_rootfs`/`relock_rootfs` now come from [`lib/rootfs.sh`](../../lib/rootfs.sh), which holds one exclusive `flock` on `/run/steam-machine-rootfs.lock` from *before* the status check until after the relock, so whoever holds it owns the read-only state for the whole of its critical section. A failed extraction also cleans up after itself now, rather than leaving the half-install that GRUB then tried to boot.

### The cache is the kernel, and it can drift silently

`~/.cache/frl-kernel/kernel.tar.zst` is the only copy of this kernel that survives an A/B update, so **whatever is in it is what the machine will be running after the next update** - not what is running now. Two ways that drifts apart, both hit on 2026-08-28:

**1. A newer build that was never cached.** The 21 August rebase onto 7.2 final was built and installed, but `--cache` was never re-run. The update wiped the slot, the self-heal restored the 8 August 7.2-rc6 tarball, and the machine came back on a kernel three weeks older than the one it went down with. `--status`'s freshness check could not see it: it compares mtimes *inside* `/usr/lib/modules/$cached_kver`, and a differently-versioned installed kernel lives in a different directory entirely.

**2. A cached pair that was never a pair.** `build_cache()` took the image from `$BUILD_TREE/arch/x86/boot/bzImage` while taking the modules from `/usr/lib/modules`. The 8 August pstore rebuild left the build tree ahead of what was installed, so the tarball ended up holding an 8 August bzImage next to 6 August modules. `CONFIG_LOCALVERSION` is unchanged across rebuilds, so both report `7.2.0-rc6-frlprobe`, `modprobe` raises nothing, and the mismatch only shows as a **hang at the boot splash with no journal at all** - the same failure `do_install()` already warns about for the vmlinuz/modules pair, arriving by a different route.

Fixed 2026-08-28: `--cache` now reads the version out of the bzImage header with `file`, packs the **installed** image with the **installed** modules, and warns when the build tree has moved ahead of what is installed. The rule that follows: **after any rebuild, install it, boot it, then `--cache` it** - in that order. A cache entry that has never booted is not a backup, it is an untested kernel scheduled to deploy itself unattended.

Worth knowing about the recovery, too: after two failed boots SteamOS fell back to the **other A/B slot**, which still held the 6 August kernel and the pre-update image, and booted it. That is why the machine stayed usable. `findmnt -no SOURCE /` tells you which slot you are on; the GRUB menu label does not.

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

# VRR range the sink advertises, and whether the driver accepted it
sudo cat /sys/kernel/debug/dri/0/HDMI-A-1/vrr_range      # Min: 40  Max: 120
sudo drm_info | grep -A2 vrr_capable                     # value: 1

# is the timing generator's dynamic vtotal armed (both *_sel must be 1)
sudo grep -A2 '^OTG:' /sys/kernel/debug/dri/0/amdgpu_dm_dtn_log

# the one remaining gap
ls /dev/cec*                                             # none

# any parameter the kernel silently threw away
sudo dmesg | grep 'unknown parameter'

# read the evidence capture (it is a file, not a generator -- see
# frl-4k120-evidence.txt for how it was produced)
less hardware/kernel/frl-4k120-evidence.txt
```

## Warning

**This is not a supported configuration and comes with no warranty of any kind.** It replaces the kernel and adds a bootloader config on a device Valve ship as an appliance. It has worked reliably here since 2026-08-06, on one machine, with one GPU and one TV. If it breaks yours, you keep both pieces.

Specifically, be aware that:

- **The VRR patches are unmerged.** `0002`-`0005` are a public mailing-list posting, reviewed but not accepted, hand-ported to a tree they were not written against. They may change or be rejected upstream.
- **Rebuilding is on you.** 7.2-rc6 → 7.2 final on 2026-08-21 → **7.2.2 on 2026-08-29**. A hand-built kernel gets no stable or CVE fixes until you rebuild it, and nothing will tell you a point release has shipped. When you do: `--install-build`, boot it, *then* `--cache`. Getting that order wrong is what cost a working kernel on 2026-08-28. The procedure is [Rebasing onto a new stable release](#rebasing-onto-a-new-stable-release).
- **You lose Valve's kernel patches** while running it. See [the gap](#the-probe-kernel-is-mainline-so-valves-patches-are-gone-m) for what that costs on a desktop.
- **A SteamOS update leaves you on the stock kernel for one boot.** Expected, not a fault - see [After a SteamOS update](#after-a-steamos-update).
- **Power-off hangs. Fixed 2026-08-08**, but by two changes rather than one — an `mt7921e` blacklist and a shutdown-time VT switch. Both are installed and kept by `install.sh`; if either goes missing the hang returns. See below.

### SOLVED: power-off hangs (2026-08-06 to 2026-08-08)

**Symptom.** `poweroff` ran the full systemd sequence and then the machine sat there — fans and lights on, TV still carrying HDR, short power-button press ignored, only a 4-second hold clearing it. Reboots were unaffected. Eight occurrences over three days.

**Two independent blockers.** Removing the first only revealed the second, and both fixes are needed.

#### 1. `mt7921e` binding the onboard MT7902 Wi-Fi

Mainline 7.2 added `14c3:7902` to `mt7921e`'s PCI table (commit `c26319afb5fb`). No Valve kernel carries that ID — 6.16 matched `7920` only, and 6.18.42 adds `7922` and `7961` but still not `7902` — which is exactly why stock powers off cleanly and this kernel did not.

The driver then fails to probe, because MediaTek have never published MT7902 *Wi-Fi* firmware to linux-firmware; only the Bluetooth blob exists. `WIFI_RAM_CODE_MT7902_1.bin` loads with `-ENOENT` and the driver logs `hardware init failed` — but the device stays bound. And `mt7921_pci_shutdown()` is a bare call to `mt7921_pci_remove()`:

```
napi_disable_locked      <- waits for a NAPI SCHED bit that never clears
mt76_dma_cleanup [mt76]
mt7921_pci_remove [mt7921e]
```

Reproducible outside shutdown entirely: `modprobe -r mt7921e` goes into `D` state and never returns.

**Fix:** `modprobe.d/mt7902-wifi.conf` blacklists it. Nothing is lost — there has never been a `wlan` interface, and Bluetooth is a separate USB device (`0e8d:7902`, `hci0`, `btusb_mt7902`). Re-check `modinfo -F alias mt7921e | grep 7902` after every SteamOS kernel bump: the day Valve ship that ID, stock inherits the same hang.

#### 2. The Gamescope session holding the GPU

With `mt7921e` gone the machine still hung, from the Steam menu and from a plain `systemctl poweroff` alike. `chvt` to a text VT beforehand fixed it: **3/3 clean power-offs with, 2/2 hangs without**. Not timing — the deciding run had `initcall_debug` off and printk at its stock `1 4 1 4`.

`gamescope` holds `/dev/dri/card0` as DRM master on `VTNr=1`. Switching away revokes that master and forces a modeset back to fbcon; shut down without doing so and something in the GPU teardown never completes.

**Fix:** `systemd/steam-machine-shutdown-vt.service` runs `chvt 4` at the *start* of shutdown, via `Conflicts=shutdown.target` plus `Before=shutdown.target`, so its `ExecStop` fires while the session is still up. VC4 rather than VC2 because `fbcon=vc:4-6` renders only VCs 4-6.

**This one is a workaround.** The underlying bug is presumably in amdgpu's shutdown path on 7.2 and has not been identified. Still present on 7.2 final, and **7.2.2 cannot have fixed it**: neither 7.2.1 nor 7.2.2 touches `drivers/gpu/drm/amd` at all. The text console you now see during shutdown is this unit working, not a fault.

Both fixes are installed by `install.sh`, listed in the atomic-update keep file, and reinstalled by `install.sh --boot` ahead of its early exit. `--status` reports both.

#### How it was found: `initcall_debug`

`device_shutdown()` prints each device's name *before* calling its handler, but only under `initcall_debug` — which is mode `0644`, so it needs no rebuild and no reboot:

```bash
echo Y > /sys/module/kernel/parameters/initcall_debug
```

The last name on screen is the culprit. Reach for this first for any "which device hangs shutdown" question; seven rounds of unloading one component at a time had established nothing, because elimination can only say what the cause is *not*.

Reading the console at all took two SteamOS-specific fixes, neither obvious:

- `steamenv_boot` force-appends `loglevel=3 splash quiet` and **strips `plymouth.enable=0`**, so editing the GRUB command line does nothing. It has to be undone at runtime.
- `fbcon=vc:4-6` means only VCs 4-6 render, so VC1 shows nothing even with plymouth gone. Hence `chvt 4`.

`bin/poweroff-test.sh` does all of that plus `initcall_debug`, and writes a marker to `/home/deck/.poweroff-test` before each attempt so a forced power-cycle does not lose which test it was. `--no-gpu` needs `--no-lact` first, because `lactd.service` holds both DRM render nodes for the whole uptime and `systemctl isolate multi-user.target` does not clear it.

#### Still open: blank screen on the boot after a forced power-off

Three times, the boot following a 4-second power-button hold stopped at a blank screen after the firmware logo, before the GRUB menu, needing another power cycle. It always cleared on the next one. Now that power-off works there should be no more forced power-offs; if it recurs, it is independent of the S5 hang.

### Hardware-specific options, and what 7.2 adds for this machine

Audited 2026-08-08, because `make olddefconfig` gives every option added since 6.16 its *Kconfig default* rather than a deliberate choice - so anything new for RDNA4 or AM5 would be off unless upstream turned it on.

**Nothing is missing.** Across every `CONFIG_` option mentioning AMD, RADEON, DRM, HSA, IOMMU, ACPI, PCI, EDAC or SENSORS that exists in *both* configs, exactly one value differs: `ACPI_PLATFORM_PROFILE` `m` → `y`, which is 7.2 making it built-in.

| Area | State |
| --- | --- |
| 9800X3D / B850 | `AMD_3D_VCACHE=m`, `X86_AMD_PSTATE=y` (default mode 3, guided), `AMD_NODE=y`, `AMD_ATL=m`, `EDAC_AMD64=m`, `GIGABYTE_WMI=m`, `PINCTRL_AMD=y`, `I2C_PIIX4=m` |
| Navi 48 | `DRM_AMDGPU=m`, `DRM_AMD_DC=y`, `DRM_AMD_DC_FP=y`, `HSA_AMD=y`, `HSA_AMD_SVM=y` |
| Off, and correctly so | `DRM_AMDGPU_SI`/`_CIK` (GCN 1/2 legacy), `HSA_AMD_P2P` (multi-GPU DMA), `DRM_RAS` (new in 7.2, aimed at datacentre parts) |

The interesting differences are **runtime module parameters**, not Kconfig.

**New in 7.2, absent from Valve's kernel:**

| Parameter | Notes |
| --- | --- |
| `hdmi_hpd_debounce_delay_ms` | Writable at runtime (`0644`). Default `0` (off); the help text calls 1500 common. Distinguishes a real unplug (longer than the delay) from a spontaneous RX HPD toggle (shorter), so brief drops no longer tear the mode down. Directly relevant to this TV - see [display](../display/README.md) for the wake-with-the-TV-off case |
| `ptl` | Boot-time only (`0444`), `-1` auto / `0` disable (default) / `1` enable / `2` permanently disable |

**Valve-only, and gone on mainline** - these are their patches, not upstream:

| Parameter | What it did |
| --- | --- |
| `allm_mode` | ALLM trigger mode: 0 disable, 1 enable (default), 2 force |
| `hdmi_vrr_desktop_mode` | HDMI VRR in desktop mode, on by default |
| `freesync_pcon_allow_all` | Let any DP→HDMI adapter past the FreeSync whitelist. Moot here - the adapter is out of the chain |

Worth knowing for ALLM specifically: mainline has **no knob** for it, so there is nothing to set. It rides the HF-VSIF path the VRR patches add.

### Kernel config: what came from Valve and what did not

The config is **seeded from Valve's**, not from `defconfig` - their `.config` at `/usr/lib/modules/<stock-kver>/build/.config` run through `make olddefconfig` against the 7.2 tree. Verified by diffing the two configs rather than by trusting this file. To re-check after any rebase:

```bash
diff <(sort /usr/lib/modules/6.16.12-*/build/.config) <(sort /home/deck/kernel-frl/build72/.config)
```

**Nothing is baked into the kernel image.** `CONFIG_CMDLINE` is unset in both, so every parameter comes from the GRUB entry - which is Valve's stock command line, minus `ttm.pages_min` (a Valve-only `ttm` parameter mainline ignores) and plus `amdgpu.dcfeaturemask=0x402`.

**Everything that matters carried over**: the full cgroup/BPF/io_uring set, `NTSYNC=m`, `SCHED_CLASS_EXT=y`, `DEBUG_INFO_BTF=y`, `HZ=1000`, `PREEMPT_DYNAMIC`, all the filesystems, `X86_AMD_PSTATE=y`, and every core PM/ACPI option - `SUSPEND`, `PM_SLEEP`, `ACPI_SLEEP`, `CPU_IDLE` all `y`. **No power-management option was lost**, which is why the config is not a candidate explanation for the power-off hang above.

230 options differ. Sorted by whether they matter:

| Category | Count | Notes |
|---|---|---|
| 6.16 → 7.2 churn | ~200 | Renamed or reorganised symbols - the `CRYPTO_*` library reshuffle, `ARCH_HAS_*`, `GENERIC_VDSO_*`, `X86_64_SMP`, `FTRACE_MCOUNT_RECORD`, `ZPOOL` folding into zswap. Not losses. |
| Hardware nobody has | ~25 | ATM, ISDN/mISDN, PCMCIA, HAMRADIO/AX25, WIZNET, InfiniBand. |
| Steam Deck handheld drivers | 5 | `MFD_STEAMDECK`, `LEDS_STEAMDECK`, `EXTCON_STEAMDECK`, `SENSORS_STEAMDECK` - Valve out-of-tree, absent from mainline, meaningless on a desktop. These are exactly the modules `mkinitcpio` complains about on every run. |
| Deliberate | 1 | `DRM_AMD_COLOR_STEAMDECK`, replaced by the `-DAMD_PRIVATE_COLOR` Makefile line in patch `0001`. |

**Genuine losses worth knowing about**, small but real:

- **`JOYSTICK_XBOX_GIP`** (plus `_FF`, `_LEDS`) - Xbox wireless controllers via the GIP dongle. Moot here (this machine uses a DualSense) but it is a real gaming regression if that ever changes.
- `LEDS_VALVE`, `HID_ASUS_ALLY`, `HID_MSI`, `ZOTAC_ZONE_*` - other vendors' handheld hardware.
- `ANDROID_BINDER_IPC` / `ANDROID_BINDERFS` - waydroid would not work.
- `BCACHEFS_FS`, `PCI_PWRCTRL`, `PCI_PWRCTRL_SLOT`.

Any of these can be turned back on with `make menuconfig` before a rebuild; none was a deliberate choice, they simply are not in mainline's `olddefconfig` answer.

The design assumes the display is the machine's only console, so a failed modeset would otherwise be a lockout. Three things make that survivable, and `install.sh` sets all of them up: `grub.cfg` is never modified, the whole FRL boot path is one file that GRUB simply skips if absent, and `set fallback` boots the stock Valve kernel automatically if the FRL entry cannot load. Before rebooting into any newly built kernel, confirm `sudo ./install.sh --status` reports `grub.cfg is stock : yes`. See the same warning in [hardware/display/](../display/README.md).
