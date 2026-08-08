# Kernel patches

Everything this machine's kernel carries on top of stock mainline, as `git format-patch` output. Applied in numeric order onto a clean `v7.2-rc6` tree they reproduce the running kernel exactly.

```bash
cd /home/deck/kernel-frl/build72
git checkout -b frl-rebuild v7.2-rc6
git am /home/deck/git/steam-machine/hardware/kernel/patches/*.patch
```

| Patch | Origin | Why it is here |
|---|---|---|
| `0001` `-DAMD_PRIVATE_COLOR` | local, 1 line | Exposes AMD's driver-private per-plane colour properties so gamescope keeps offloading HDR. Upstream guards that code with a define it never sets; SteamOS sets it via `CONFIG_DRM_AMD_COLOR_STEAMDECK`, which does not exist upstream. Valve's own commit conflicts on 7.2; this does the same job in the `amdgpu_dm` Makefile. |
| `0002` HF-VSDB gaming caps | upstream, unmerged | DRM core: parses HDMI 2.1 ALLM/VRR capabilities out of HF-VSDB bytes 8/9/10, which mainline drops on the floor. |
| `0003` FreeSync over AMD VSDB | upstream, unmerged | Accepts `SIGNAL_TYPE_HDMI_FRL` when parsing the AMD VSDB, and emits the VTEM infopacket on FRL streams. |
| `0004` HDMI 2.1 VRR from HF-VSDB | upstream, unmerged | Falls back to the HDMI Forum VRR range when the AMD VSDB provides none. |
| `0005` HDMI ALLM | upstream, unmerged | Sends the HF-VSIF with `ALLM_Mode=1` when the sink supports it and content type is Game or VRR is active. |
| `0006` restore FRL cap on non-destructive verify | upstream, unmerged | One line. Without it an established FRL link **collapses to TMDS across a hotplug** — and since VRR keys on `SIGNAL_TYPE_HDMI_FRL`, it takes VRR with it. |
| `0007` 2026 Steam Controller device IDs | Valve | Four `#define`s: `IBEX` `0x1302` wired, `IBEX_BLE` `0x1303` Bluetooth, `PROTEUS` `0x1304` the puck, `NEREID` `0x1305`. |
| `0008` `hid-steam` 2026 controller support | Valve, **not upstream** | Valve's `hid-steam.c` verbatim from `6.18.42-valve2`. Without it the puck falls through to `hid-generic` and `hid_steam` never loads. |

## Provenance of 0007-0008: Valve's, and nowhere else

These two come from Valve's own kernel rather than a mailing list, which makes them different in kind from 0002-0006 and worth treating with more suspicion at each rebase.

**They are not upstream.** Checked 2026-08-08 against both `torvalds/linux.git` and the HID maintainer tree `hid/hid.git`: the newest `drivers/hid/hid-steam.c` commits in either are from the 6.15 era ("Use new BTN_GRIP* buttons", "Remove the unused variable connected"). Nothing referencing IBEX, PROTEUS or NEREID exists in public kernel git. Valve have not posted the series to linux-input.

**Getting them requires the full source package.** Valve's git is `git+ssh://` and needs credentials; anonymous HTTPS returns 403. The only public route is the 3.5 GB source package, which embeds a bare repo:

```bash
curl -fLO https://steamdeck-packages.steamos.cloud/archlinux-mirror/sources/jupiter-3.8/linux-neptune-618-6.18.42.valve2-1.src.tar.gz
tar -xzf linux-neptune-618-6.18.42.valve2-1.src.tar.gz
git -C linux-neptune-618/archlinux-linux-neptune show refs/tags/6.18.42-valve2:drivers/hid/hid-steam.c
```

Pin the tag matching the stock kernel you are comparing against — `6.18.42-valve2` is `af6356cf2488`.

**`hid-steam.c` is taken verbatim; `hid-ids.h` must not be.** Valve's 6.18 header predates the Harmonix and PDP RiffMaster IDs that 7.2 added, so copying it wholesale removes definitions other in-tree HID drivers need and the build fails on a dozen unrelated errors. Only four defines are actually missing — confirmed by extracting every `USB_*_ID_*` symbol the driver references (8) and diffing against the mainline header.

**No Kconfig or Makefile change is needed.** Valve's diffs for both files are entirely their other drivers; neither contains a `hid-steam` hunk.

Valve's 6.18 driver compiles against 7.2-rc6 with **no source changes**, which is the part worth re-testing rather than assuming after any rebase.

## Why 0006 matters here more than its size suggests

`verify_link_capability_non_destructive()` in `link_detection.c` assigned the *DP* `verified_link_cap` on the HDMI branch and left `frl_verified_link_cap` stale, so `frl_link_rate` read back as `HDMI_FRL_LINK_RATE_DISABLE` and the stream fell back to TMDS. A TV that gets switched off and on is a routine HPD event on this machine, and the symptom would be a silent drop to 4K60 with no error anywhere and `--status` still reporting everything installed.

Provenance: **Fangzhi Zuo** (AMD), Reviewed-by **Harry Wentland**. Posted standalone on 30 July 2026 (`20260730205047.1016922-1-jerry.zuo@amd.com`) and picked up into Tom Chung's **"DC Patches Aug 10 2026"** as patch 31/34 (`20260805063937.2145774-32-chiahsuan.chung@amd.com`), which is the merge path — so this one should land upstream on its own and can be dropped at the next rebase.

## Provenance of 0002–0005

All four are **Fangzhi Zuo's** (AMD) series, posted to `amd-gfx` on **30 July 2026** and reviewed by **Harry Wentland** on 31 July. Message-ID `20260730171754.704049-1-jerry.zuo@amd.com`. To re-fetch the thread:

```bash
curl -A 'git/2.5' -o series.mbox.gz \
  'https://lore.kernel.org/amd-gfx/20260730171754.704049-1-jerry.zuo@amd.com/t.mbox.gz'
```

`lore.kernel.org` is behind Anubis proof-of-work, so a default `curl` user-agent gets a challenge page instead of the mbox. A git user-agent passes.

**They are unmerged.** They are not in `v7.2-rc6`, and not in `amd-staging-drm-next` — but note *why* not: that branch's tip is `d8ab7636160e`, dated 29 July, one day before the series was posted, and it has not moved since. Re-check before rebuilding:

```bash
cd /home/deck/kernel-frl/build72
git fetch agd5f amd-staging-drm-next
git log --oneline FETCH_HEAD -i --grep='HF-VSDB' --grep='ALLM' -- drivers/gpu/drm
```

If they have landed, drop `0002`–`0005` and take the merged versions instead.

## What "hand-ported" means here

The upstream patches are against `amd-staging-drm-next`, which has split `amdgpu_dm_connector.c` out of `amdgpu_dm.c`. Mainline has not, so those hunks were moved into `amdgpu_dm.c`. The surrounding code is identical in both trees — this is relocation, not a rewrite. Three other differences:

- `amdgpu_dm_get_highest_refresh_rate_mode()` is plain `get_highest_refresh_rate_mode()` in mainline.
- The `STATIC_IFN_KUNIT` / `EXPORT_IF_KUNIT` wrappers around `get_freesync_config_for_crtc()` are staging-only; the debug line went into the plain static function.
- `0005` is applied **as posted**, including the `dc_edid_caps.allm` field. Harry's review asked for the ALLM bit to be read from `aconn->base.display_info.hdmi.allm` instead, which would drop the `dc_types.h` and `amdgpu_dm_helpers.c` hunks. If a v2 appears upstream, take that rather than this.

Each patch's commit message records its own deviations.

## Rebuilding from these

Build steps are in [../README.md](../README.md#3-config-and-build). After a successful build:

```bash
sudo ../install.sh --cache     # repack the artefact tarball from the build tree
sudo ../install.sh --install   # deploy, regenerate initramfs, rewrite custom.cfg
```

**Watch the version string.** `CONFIG_LOCALVERSION="-frlprobe"` is unchanged by `0002`–`0006`, so a rebuild produces the *same* `7.2.0-rc6-frlprobe` release string and overwrites `/usr/lib/modules/7.2.0-rc6-frlprobe` and `/boot/frl/` in place. There is no second menu entry to fall back to. Before deploying a rebuild, keep the working artefact under a name that says what it predates:

```bash
cp -n ~/.cache/frl-kernel/kernel.tar.zst ~/.cache/frl-kernel/kernel.tar.zst.pre-<change>
```

Kept so far: `.pre-vrr` (before `0002`–`0005`) and `.pre-frlrestore` (before `0006`).

To roll back: boot the stock Valve kernel from the GRUB menu, then

```bash
cp ~/.cache/frl-kernel/kernel.tar.zst.pre-vrr ~/.cache/frl-kernel/kernel.tar.zst
sudo rm -rf /boot/frl /usr/lib/modules/7.2.0-rc6-frlprobe
sudo ../install.sh --install
```

`--install` now redeploys the tarball unconditionally, so restoring the backup and re-running it is sufficient; it used to skip the extract when the old files were still present, which made this rollback a no-op.

Bumping `CONFIG_LOCALVERSION` for a rebuild would let both kernels coexist with their own menu entries, at the cost of a full module rebuild and a second copy of the modules. Worth it for a risky change; not done here.

The stock Valve kernel is untouched throughout, and `set fallback` in `custom.cfg` boots it automatically if the FRL entry cannot load.
