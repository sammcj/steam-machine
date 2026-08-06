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

**Watch the version string.** `CONFIG_LOCALVERSION="-frlprobe"` is unchanged by `0002`–`0005`, so a rebuild produces the *same* `7.2.0-rc6-frlprobe` release string and overwrites `/usr/lib/modules/7.2.0-rc6-frlprobe` and `/boot/frl/` in place. There is no second menu entry to fall back to. Before deploying a rebuild, keep the working artefact:

```bash
cp -n ~/.cache/frl-kernel/kernel.tar.zst ~/.cache/frl-kernel/kernel.tar.zst.pre-vrr
```

To roll back: boot the stock Valve kernel from the GRUB menu, then

```bash
cp ~/.cache/frl-kernel/kernel.tar.zst.pre-vrr ~/.cache/frl-kernel/kernel.tar.zst
sudo rm -rf /boot/frl /usr/lib/modules/7.2.0-rc6-frlprobe
sudo ../install.sh --install
```

Bumping `CONFIG_LOCALVERSION` for a rebuild would let both kernels coexist with their own menu entries, at the cost of a full module rebuild and a second copy of the modules. Worth it for a risky change; not done here.

The stock Valve kernel is untouched throughout, and `set fallback` in `custom.cfg` boots it automatically if the FRL entry cannot load.
