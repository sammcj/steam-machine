# btop GPU monitoring

Makes btop's GPU box work on this machine. Without this, the setting exists in btop's options but the box never appears.

```
sudo ./install.sh         install the ROCm SMI library and enable the GPU box
./install.sh --status     report current state
```

## The problem

btop here is 1.4.4, built `GPU_SUPPORT=true` — so GPU support is compiled in and the options are real. But its **only AMD backend is the ROCm SMI library**, which SteamOS does not ship. The `/sys/class/drm` code in btop is for the Intel backend; AMD has no sysfs path.

With no library, btop finds no GPU and **silently removes `gpu0` from `shown_boxes` when it exits**. Setting it in the options menu appears to work until you restart btop, which is exactly what "I can see the setting but no GPU information" looks like.

`LD_LIBRARY_PATH` does not help — btop never dlopens by soname. Traced with `strace`, it tries five absolute paths and nothing else:

```
openat("/opt/rocm/lib/librocm_smi64.so",  ...) = -1 ENOENT
openat("/usr/lib/librocm_smi64.so",       ...) = -1 ENOENT
openat("/usr/lib/librocm_smi64.so.5",     ...) = -1 ENOENT
openat("/usr/lib/librocm_smi64.so.1.0",   ...) = -1 ENOENT
openat("/usr/lib/librocm_smi64.so.6",     ...) = -1 ENOENT
```

## Why /opt, and why this subsystem has no keep entry

Four of those five paths are under `/usr` — the read-only rootfs an A/B update replaces wholesale. The fifth is not:

```
$ findmnt -no SOURCE /opt
/dev/nvme0n1p8[/.steamos/offload/opt]
```

`/opt` is a **SteamOS offload mount**, bind-mounted from the home partition. So it is writable without unlocking the rootfs, and it survives OS updates by itself. Unlike every other subsystem in this repo, this one needs no `/etc/atomic-update.conf.d` entry and no boot self-heal — there is nothing for an update to take away. `--status` verifies the offload mount is still what it claims to be, so if that assumption ever changes it shows up rather than failing quietly.

The same mechanism covers `/root`, `/srv`, `/nix`, `/var/log`, `/var/lib/flatpak` and others — worth knowing generally, since it is the opposite of the usual SteamOS assumption that anything outside `/home` is disposable:

```
$ findmnt | rg offload
```

## Why only one library

`rocm-smi-lib` declares dependencies on `rocm-core`, `hsa-rocr`, `rocm-device-libs`, `rocprofiler-register` and more — around 400 MB of ROCm stack. None of it is needed. `readelf -d` on the library itself:

```
NEEDED  libstdc++.so.6
NEEDED  libm.so.6
NEEDED  libgcc_s.so.1
NEEDED  libc.so.6
```

So `install.sh` downloads the 1.1 MB package, verifies its SHA256, and extracts exactly one 4 MB `.so` plus its soname symlinks. Nothing else from ROCm is installed.

## Result

```
╭─┐⁵gpu0┌──────────────────────────────────────────────────────────────────────╮
│              ╭─┐Navi 48 [Radeon RX 9070/9070 XT/9070 GRE]┌───────────┐0 MHz┌╮│
│              │GPU ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■   0% ⣀⣀⣀⣀⣀⣀  22°C ││
│              │PWR ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■ 8.00W  ││
│              ├─┐vram┌──────────────┐1258 MHz┌┬─Used:───────────1,59 GiB─┤│
│              │ Total:               15,9 GiB │  10%                     ││
╰──────────────────────────────────────────────────────────────────────────────╯
```

Utilisation, temperature, power draw, VRAM and clocks, all live. The `gpu0` box is placed immediately after `cpu` in `shown_boxes` so it renders below the CPU box.

The integrated GPU also appears — the 9800X3D has Raphael graphics (`0x13c0`), so ROCm reports two devices and btop shows the iGPU as `GPU1` inside the CPU box. `show_gpu_info = "Off"` in btop.conf turns that off if it's noise; the `gpu0` box is unaffected.

## Layout: CPU and GPU cannot sit side by side

Asked for and tested 2026-08-03, not possible. btop's box geometry is hardcoded; the only layout options in btop.conf are `cpu_bottom`, `mem_below_net` and `proc_left`, and there is no GPU equivalent. Verified by rendering `shown_boxes = "cpu gpu0"` and `"cpu gpu0 gpu1"` at 150 and 190 columns — boxes always stack vertically at full width, and even two GPU boxes stack rather than splitting.

Two workarounds, neither applied:

- `show_gpu_info = "On"` with the `gpu0` box off puts GPU graphs beside the CPU cores *inside* the cpu box. Native and cheap, but it always renders every detected GPU, so with the Raphael iGPU present it splits three ways rather than half and half, and it loses the VRAM/clocks panel. The iGPU cannot be hidden: `ROCR_VISIBLE_DEVICES`, `HIP_VISIBLE_DEVICES` and `RSMI_VISIBLE_DEVICES` were all tested and none has any effect, because rsmi enumerates from sysfs directly rather than through the HSA runtime.
- Two btop instances in a tmux split (`btop -c <file>` takes a config path), one with `shown_boxes = "cpu"` and one with `"gpu0"`. This does give a true 50/50 with the full GPU panel, at the cost of a second process.

## Notes

- **Quit btop before running the installer.** btop rewrites `btop.conf` on exit, so edits made while it is running are discarded. `install.sh` refuses to run if it sees a live btop rather than losing the change silently.
- The library gives btop real per-GPU data, unlike the CPU temperature situation described in [system/htop/](../htop/README.md) — GPU sensors genuinely are per-device, so nothing here is a repeated package figure.
- For temperature and power *over time*, CoolerControl on port 11987 is still the better tool. See [hardware/coolercontrol/](../../hardware/coolercontrol/README.md).
