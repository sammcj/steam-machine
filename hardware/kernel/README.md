# Kernel — HDMI 2.1 FRL for 4K120 on the native HDMI port

## Status: working, but as a temporary probe kernel

**4K 120 Hz, RGB 4:4:4, 12 bpc, uncompressed, HDR10, zero underflow — over the GPU's native HDMI port**, on a hand-built mainline **Linux 7.2-rc6**. Achieved 2026-08-06. The UGREEN DP→HDMI converter is out of the chain entirely.

This is strictly better than what the converter delivered: it managed 10 bpc *with* DSC, plus intermittent glitching and no CEC. See [hardware/display/](../display/README.md) for that setup, which this replaces.

Full measurement capture, with the raw debugfs output it was read from: [`frl-4k120-evidence.txt`](frl-4k120-evidence.txt).

**It will not survive a SteamOS update.** Everything below lives on the A/B rootfs slot and the per-slot EFI partition, both of which are replaced wholesale. That is deliberate for a probe — see [Making it survive updates](#making-it-survive-updates) for what turning this into a permanent subsystem would take.

## What was measured

| | |
|---|---|
| Mode | 3840×2160 @ 120 Hz |
| Pixel clock | **1187.20 MHz** (htotal 4399 × vtotal 2249 × 120) |
| HDMI 2.0 TMDS ceiling | 600 MHz — the link is running at **1.98×** it |
| Lanes | 4 |
| Pixel format | RGB 4:4:4 |
| Bit depth | 12 bpc |
| DSC | `CLOCK_EN 0` — uncompressed |
| ODM segments | 0 — single pipe, no combine |
| Underflow | `0h` on every active pipe |
| HDR | `Colorspace = 9` (`DRM_MODE_COLORIMETRY_BT2020_RGB`) while an HDR game runs |
| Content type | `4` (Game) — drives HDMI ALLM |

The pixel clock is the proof on its own. 600 MHz is a hard ceiling for TMDS signalling; 1187 MHz is only reachable over FRL.

**Note the ODM row.** [hardware/display/](../display/README.md) records that ODM 2:1 combine is mandatory for 4K120 on this machine, because ~1.19 GHz is more than one DCN pipe can clock out. That holds for the **DP + converter** path it was measured on. It does not hold here: over native FRL the HPO block reports `ODM Segments 0` and every HUBP pipe is the full 3840 wide, not the ~1922 that ODM 2:1 produces. Single pipe, no combine, at the same pixel clock. Worth remembering, because the centre-screen seam that was investigated at length on the converter was suspected of being an ODM stitching artefact — this path does not stitch at all.

Two further confirmations that the *native* FRL path is what's carrying it, rather than the old DP-to-HDMI PCON code that has been in amdgpu for years:

- dmesg contains `hdmi_frl_status_polling_workque` — a workqueue created only by the 7.2 FRL code.
- `amdgpu_dm_dtn_log` populates the **HPO** block (`Lanes 4`, `Borrow ACTIVE`), the FRL stream encoder path. On the converter this block was empty and the DP link block was populated instead.

For HDR specifically, `Colorspace = 9` is the exact test gamescope uses in `CDRMConnector::IsHDRActive()`. On the SDR desktop the same property reads `0`; it flips to `9` when an HDR title starts, and the composited plane's HUBP surface format changes `8h` → `18h` (32-bit ARGB8888 → a 64-bit half-float surface).

## Why no SteamOS kernel could do this

The `amdgpu` in every Valve kernel has no native HDMI 2.1 FRL, which caps the HDMI port at 600 MHz TMDS. 4K120 4:4:4 needs ~1188 MHz, so the port simply could not light the mode.

Verified rather than assumed — the `amdgpu.ko` was extracted from the Valve packages and its symbol table compared:

- `linux-neptune-616-drm-exec` 6.16.12 (what SteamOS 3.8 ships)
- `linux-neptune-618-drm-exec` 6.18.33
- `linux-neptune-618` 6.18.38

**All three have a byte-identical FRL symbol set.** The `*frl*` symbols they do contain (`dc_link_bw_kbps_from_raw_frl_link_rate_data`, `DC_LINK_ENCODING_HDMI_FRL`, the `dml*_hdmifrl` naming) all belong to the DP-to-HDMI PCON path — configuring an *external* converter's FRL, not driving FRL from the GPU's own encoder. None of them contain `dcn401_hpo_frl_stream_encoder`, `link_hdmi_frl` or `link_hwss_hpo_frl`.

Upstream, FRL landed in **Linux 7.2** ([Phoronix](https://www.phoronix.com/news/Linux-7.2-DRM)), from Harry Wentland's `[PATCH RESEND v3 00/14] HDMI FRL and DSC Support for amdgpu` — 14 patches, 179 files, +15,176/−120. DCN 4.0.1 (this GPU) is explicitly in scope: the series adds `dcn401_hpo_frl_stream_encoder.c` and +220 lines to `dcn401_dio_link_encoder.c`.

It ships **disabled by default**, gated behind `DC_FRL_MASK = (1 << 10)` in `drivers/gpu/drm/amd/include/amd_shared.h`, because HDMI VRR is not ready and AMD consider FRL-without-VRR a regression for existing users.

### Two traps in the widely-quoted incantation

Every article says to boot with `amdgpu.dc_feature_mask=0x400`. That is wrong twice:

1. **The parameter is spelled `dcfeaturemask`.** `dc_feature_mask` is the name of the C variable, not the module parameter. Confirmed with `modinfo`.
2. **It replaces the mask, it does not OR into it.** The default on this machine is `2` (`DC_MULTI_MON_PP_MCLK_SWITCH_MASK`). Passing `0x400` would silently turn that bit *off*. The correct value is **`0x402`**.

## How it was built

Reproducible from scratch. The whole thing took about two hours, most of it unattended compile time.

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

Gamescope offloads HDR colour management onto DCN hardware via AMD's driver-private per-plane properties (`AMD_PLANE_CTM`, `BLEND_TF`, `SHAPER_LUT`, `LUT3D`, `HDR_MULT`, …). SteamOS enables them with `CONFIG_DRM_AMD_COLOR_STEAMDECK=y`, which does not exist upstream.

That turned out to be a non-issue. **All of the code is already in mainline** — in `amdgpu_dm_color.c`, `amdgpu_dm_crtc.c` and `amdgpu_dm_plane.c` — guarded by `#ifdef AMD_PRIVATE_COLOR`, a bare define mainline never sets. Upstream's own documentation in `amdgpu_dm_color.c` says the properties are exposed "when the kernel is built explicitly with `-DAMD_PRIVATE_COLOR`".

Valve's commit (`0f3a9b934bc3`, authored by Melissa Wen at Igalia, tagged `[NOT-FOR-UPSTREAM]`) is nothing more than a 7-line Kconfig entry plus six one-line `#ifdef` renames. Cherry-picking it onto 7.2 conflicts in three files because it dates from 2023. One line in `drivers/gpu/drm/amd/display/amdgpu_dm/Makefile` achieves the same thing with no conflicts:

```make
subdir-ccflags-y += -DAMD_PRIVATE_COLOR
```

Verified afterwards: all five properties gamescope checks for are present in the built `amdgpu.ko`, and HDR offload works.

### 3. Config and build

Seed from Valve's config so the machine keeps everything it depends on — `SCHED_CLASS_EXT=y` for the installed `scx-scheds`, `DEBUG_INFO_BTF=y`, the lot:

```bash
cd build72
cat ../linux-neptune-618-drm-exec/config.x86_64 > .config
cat ../linux-neptune-618-drm-exec/config-neptune >> .config
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-frlprobe"/; \
        s/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' .config
```

The `override: reassigning to symbol …` warnings from `olddefconfig` are the neptune fragment overriding the base config. That is what it is for.

Build in a container — the host is missing `bc`, `flex` and `bison`, and the rootfs is read-only:

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

## What is installed on the machine

Five additions. **Nothing existing was edited** — no Valve-shipped file was touched.

| Path | What |
|---|---|
| `/boot/vmlinuz-linux-frlprobe` | the kernel |
| `/boot/initramfs-linux-frlprobe{,-fallback}.img` | generated by mkinitcpio |
| `/usr/lib/modules/7.2.0-rc6-frlprobe/` | modules, incl. `updates/{it87,btusb_mt7902}.ko` |
| `/etc/mkinitcpio.d/linux-frlprobe.preset` | so mkinitcpio knows about it |
| `/etc/default/grub.d/70-frlprobe-boot.cfg` | pins `GRUB_DEFAULT` to the stock kernel |
| `/efi/EFI/steamos/custom.cfg` | menu timeout + the one FRL boot entry |

Build tree and source stay outside the repo in `/home/deck/kernel-frl/` (~40 GB).

### The boot-safety problem, and the two things that fix it

The TV is this machine's only console. A kernel that fails to modeset is a lockout, so two separate traps had to be dealt with.

**`GRUB_DEFAULT=0` is not safe once a second kernel exists.** `10_linux` emits the newest kernel as the top-level `SteamOS` entry and pushes older ones into the "Advanced options" submenu, so installing 7.2 would silently make the *test* kernel the unattended boot target. Fixed by pinning to the stock entry's **id**, not its index:

```
GRUB_DEFAULT="gnulinux-advanced-<uuid>>gnulinux-linux-neptune-616-drm-exec-advanced-<uuid>"
```

**`GRUB_TIMEOUT` does nothing on SteamOS.** Valve's "steamenv header sub block" hardcodes `timeout=0` at line ~79 of the generated `grub.cfg` and ignores the `/etc/default/grub*` setting entirely — so no menu ever appears and an alternate kernel is unreachable. The override has to go somewhere that runs *later*. `/etc/grub.d/41_custom` sources `${config_directory}/custom.cfg` at line ~211, which is after it:

```
# /efi/EFI/steamos/custom.cfg
set timeout=10
set timeout_style=menu
```

That file also carries the FRL menu entry. Defining it there rather than via `GRUB_CMDLINE_LINUX` is deliberate: a `grub.d` drop-in injects into **every** entry, including the stock 6.16 one. The first attempt did exactly that, and it was caught by diffing the generated 6.16 command line against the live `/proc/cmdline`. With the entry defined in `custom.cfg`, `dcfeaturemask` appears zero times in `grub.cfg` and the stock kernel boots byte-identically to before.

(For the record, `0x402` on 6.16 would have been harmless — its highest defined bit is `DC_REPLAY_MASK = (1 << 9)`, so bit 10 is undefined there. "Harmless" is not the same as "unchanged", and the fallback kernel should be unchanged.)

### Rollback

[`rollback.sh`](rollback.sh) removes all of it and regenerates `grub.cfg`. It refuses to run while the probe kernel is the running kernel, and refuses to finish — telling you not to reboot — if `update-grub` fails or the stock kernel is missing from the regenerated config.

```bash
sudo ./rollback.sh
```

Recovery layers, in order: do nothing at the menu (10 s → stock 6.16, pinned by id) → power-cycle → ssh in → `rollback.sh` → `steamcl.efi` and the A/B slots are untouched.

## Gaps

### CEC still does not work (M)

One of the two reasons for leaving the converter, and **the native port does not fix it**. The `cec` module is loaded and `drm_display_helper` and `amdgpu` both reference it, but **no CEC adapter is registered** and there is no `/dev/cec*` node.

The `hdmi_cec_state` debugfs entry reports `HDMI-CEC status: 1`, but that is the *sink's* advertised CEC capability read over DDC — not a Linux CEC adapter. amdgpu has never exposed one for its own HDMI ports; the `cec` dependency comes from `drm_display_helper`'s DisplayPort CEC-tunnelling path, which needs a DP branch device.

Addressing it means one of:

- **A USB CEC adapter** (Pulse-Eight or similar) — `cec-gpio`/`usbcec` register a real adapter and `libcec` works. Costs a USB port and about $60 AUD. The only option that works today.
- **Wait for amdgpu to implement it.** No sign of it upstream. i915 and the DW-HDMI bridge drivers have CEC adapters; amdgpu does not.
- **HDMI-CEC over the TV's own eARC/SIMPLINK** for the subset of things the TV can do itself — does not give the machine control.

### VRR still does not work (L)

`vrr_range` reads `Min: 0  Max: 0` and `vrr_capable` is `0`. Expected: 7.2 shipped FRL **without** HDMI VRR, which is precisely why FRL is disabled by default there. Upstream commit `c3778921bf0d` says so in its own message.

Note this is not a regression — VRR did not work through the converter either, for a different reason (it did not pass FreeSync through at all; see [hardware/display/](../display/README.md)).

The ALLM + HDMI VRR series is in review and lines up with **7.3**. When it lands, revisit. The C9 supports 40–120 Hz VRR, so there is a real gain waiting.

### The probe kernel is mainline, so Valve's patches are gone (M)

Not currently causing a visible problem, but worth being explicit about. Running 7.2-rc6 means the machine has lost:

- `allm_mode`, `hdmi_vrr_desktop_mode`, `freesync_pcon_allow_all` — Valve's out-of-tree amdgpu parameters, all confirmed absent from mainline `amdgpu_drv.c`
- Whatever the `drm-exec` branch itself carries (unexamined — the tree is available now, so this is answerable)

Everything else in `config-neptune` is either Steam Deck / handheld hardware that does not exist on an AM5 desktop (Vangogh audio, `MFD_STEAMDECK`, `LTRF216A`, the Lenovo/Asus/Zotac/OneXPlayer/MSI HID drivers) or plain config flags that were carried across by seeding from Valve's config.

## Next steps

### 1. Rebase onto Valve's kernel rather than running mainline (H)

The end state is Valve's 6.18-drm-exec **plus** the FRL commits, so the machine keeps Valve's patches and gains FRL. All the pieces are already local:

- the Valve bare repo at tag `6.18.33-drmexec-valve2`
- `v7.2-rc6` fetched into the same repo, so the commits are directly cherry-pickable

The commits to take, all verified present in `v7.2-rc6` (`075b74841bd0`):

| SHA | Subject |
|---|---|
| `c3778921bf0d` | Disable FRL and add module param to enable it |
| `443290d70b01` | Add AV mute wait frames to `dce110_set_avmute` |
| `c216b39fbbc4` | Increase HDMI AV mute wait from 2 to 3 frames |
| `fed376e1f2e3` | Fix kdoc parameter names for DSC padding helper |
| `ee911514a9f8` | Rename `hdmi_frl_borrow_mode` |
| `5726af470517` | Widen FRL debug knobs to unsigned int |
| `1e13b7eb67f9` | Widen `dc_hdmi_frl_flags.force_frl_rate` to unsigned int |

Plus the 14-patch series itself and the ~9 register-header commits that were split out of it before merge (they landed separately on 2026-05-11 — a `git am` of the mailing-list v3 mbox will *not* compile without them, which is why cherry-picking merged SHAs is the right route).

The two AV-mute commits are `Cc: stable` and fix "garbled display after link re-establishment". That is worth having on a TV.

Expect real work: `dc/dml2` was renamed to `dc/dml2_0` in 6.19, and there are roughly 740 commits of DC churn between 6.18 and 7.2. Budget a day, not an afternoon.

### 2. Or just wait for 7.2 final, then for Valve (L)

7.2 final is due 16–30 Aug 2026. Valve are on 6.18 now, so a 7.2-based neptune kernel is likely months away, and they may well leave FRL disabled since upstream does.

### 3. Answer the open question about `drm-exec` (L)

The Valve tree is now local. `git log v6.18..6.18.33-drmexec-valve2` against a fetched upstream tag will list exactly what Valve add, which retires the "unexamined" caveat above.

## Making it survive updates

Nothing here is currently persistent. A SteamOS A/B update replaces the rootfs slot and the per-slot EFI partition, taking the kernel, its modules, the mkinitcpio preset, the grub drop-in and `custom.cfg` with it. The machine reverts cleanly to stock 6.16 — which is a safe failure, just an annoying one.

Two levels of fix, in increasing order of effort.

### Level 1: easy to reinstall (recommended next)

Keep the built artefacts on `/home` (which survives everything) and add an `install.sh` that redeploys them. Concretely:

1. **Package the kernel** with `makepkg` instead of hand-copying, producing a `.pkg.tar.zst` in `/home/deck/kernel-frl/`. `pacman -U` then handles modules, `depmod` and the mkinitcpio trigger. The PKGBUILD needs its `source=` rewritten to `git+file:///home/deck/kernel-frl/…` (the `git+ssh://` URL cannot be fetched) and a `pkgbase` that cannot collide with Valve's, e.g. `linux-neptune-618-frl`.
2. **`install.sh --boot`** that reinstalls the package if `/boot/vmlinuz-*-frl` is missing, rebuilds `it87` and `btusb_mt7902` against it, rewrites the grub drop-in and `custom.cfg`, and runs `update-grub`. Same self-heal pattern as [hardware/sensors/](../sensors/README.md) and [hardware/bluetooth/](../bluetooth/README.md), placed before any fast-path early exit.
3. **A systemd unit** to run it at boot. `/etc/systemd/system/*.service` **is** on the SteamOS keep list, so the unit itself persists even though everything it installs does not.

After an update the machine boots stock 6.16, the unit re-installs the FRL kernel, and the *next* boot can select it. Roughly 200 MB of rootfs per install against ~775 MB free — it fits, but it is not roomy.

### Level 2: fully automatic

Everything in level 1, plus making the FRL kernel the boot default so no menu interaction is needed after an update. **Do not do this until the kernel has weeks of uptime behind it.** Pinning an unproven kernel as the default on a machine whose only console is the TV is exactly the lockout this setup was carefully built to avoid.

If it is done, the guard is `/etc/atomic-update.conf.d/steam-machine-kernel.conf` naming the **specific files** (never the directory — an allowlisted path shadows all future upstream versions of it forever), and a fallback that reverts `GRUB_DEFAULT` to the stock entry after a failed boot. Valve's `steamcl.efi` already tracks `boot-attempts`/`boot-count` in `/esp/SteamOS/conf/{A,B}.conf`; whether that can be hooked for a per-kernel fallback is unexamined.

### What is *not* worth persisting

The 40 GB source and build tree in `/home/deck/kernel-frl/`. Once a package exists, keep the `.pkg.tar.zst` (~150 MB) and delete the rest; the tree is reproducible from the source package plus a `git fetch`.

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

The TV is this machine's only console. Before rebooting into any newly built kernel, confirm the generated `/efi/EFI/steamos/grub.cfg` still lists the stock kernel and that `set default=` names it. See the same warning in [hardware/display/](../display/README.md).
