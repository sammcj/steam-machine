# htop configuration

Keeps this machine's htop layout for both `deck` and `root` across reboots and SteamOS A/B updates.

```
./install.sh              install for root and deck (idempotent)
./install.sh --save       copy deck's live htoprc back into the repo
sudo ./install.sh --apply force repo -> both destinations
./install.sh --status     report current state
```

## The problem

htop reads its config from the first of these that exists:

```
$HTOPRC
$XDG_CONFIG_HOME/htop/htoprc
~/.config/htop/htoprc
~/.htoprc
/etc/htoprc                 <- read-only fallback
```

**Neither account loses its config to a SteamOS update.** Both home directories are on the home partition (`nvme0n1p8`, ext4), which updates never touch:

```
$ findmnt -no TARGET,SOURCE /root /home
/root  /dev/nvme0n1p8[/.steamos/offload/root]
/home  /dev/nvme0n1p8
```

`/root` is a **SteamOS offload mount** — bind-mounted from the home partition, not part of the rootfs subvol an A/B update replaces. It is also writable regardless of `steamos-readonly`. (An earlier version of this file claimed the opposite, inferred from the rootfs mount without checking `/root` itself. It was wrong; `/opt`, `/srv`, `/nix`, `/var/log` and `/var/lib/flatpak` are offloaded the same way — see [system/btop/](../btop/README.md), which depends on that property for `/opt`.)

So if settings revert for either account, an OS update is not the cause. The two real causes:

1. **htop only saves on a clean exit.** Quit with `q`. Ctrl-C, closing the terminal, or a dropped SSH session sends a signal, and htop logs `A signal N (...) was received, exiting without persisting settings to htoprc` — every change made that session is discarded.
2. **A root-owned htoprc in deck's home.** `sudo htop` inheriting `HOME=/home/deck` rewrites the file as root. After that htop still *displays* the right layout and still *accepts* changes, but silently fails to save them, with no error. `./install.sh --status` checks for this.

## The fix

`/etc/htoprc` carries the config, allowlisted so it survives updates. root picks it up via the fallback above, which gives both accounts one config to maintain instead of two.

`/etc` genuinely does need the allowlist and the self-heal, even though `/root` and `/home` do not: it is an overlayfs whose upper layer lives in `/var`, and a SteamOS atomic update discards that upper layer except for allowlisted paths. That is the part of this subsystem an update can actually break.

| File | Purpose |
| --- | --- |
| `/etc/htoprc` | system-wide config — root, and any account without its own |
| `/etc/atomic-update.conf.d/steam-machine-htop.conf` | keeps the above across A/B updates |
| `/etc/systemd/system/steam-machine-htop.service` | restores both at boot, in case the allowlist entry itself was lost |
| `~deck/.config/htop/htoprc` | deck's copy, owned by deck |

All three `/etc` paths are on an overlayfs with its upper layer in `/var`, so none of this needs the rootfs unlocked.

The boot unit restores `/etc/htoprc` whenever it **differs** from the repo (nothing on the system writes that file, so any difference means an update removed it), but restores deck's copy only when **missing** — `/home` survives updates, so a difference there is a deliberate in-htop tweak, and overwriting it every boot would undo exactly the settings this is meant to keep.

### Round-tripping changes

The repo is the source of truth, but htop is the editor. After tweaking settings in htop and quitting with `q`:

```
./install.sh --save        # live config -> repo
sudo ./install.sh --apply  # repo -> /etc/htoprc and deck
git add -A system/htop && git commit
```

One wrinkle `--apply` handles: as soon as root runs htop and exits cleanly it writes `/root/.config/htop/htoprc`, which then shadows `/etc/htoprc` — permanently, since `/root` is offloaded and nothing ever clears it. `--apply` removes that file so an updated `/etc/htoprc` reaches root again. Without it, root would silently keep whatever layout it last captured.

## CPU frequency and temperature in htop

`show_cpu_frequency=1` and `show_cpu_temperature=1` are both set. Measured behaviour on this machine:

```
0[||||||||||||||||          25.3% 1299MHz N/A]   4[||||||||||    17.1% 5199MHz N/A]
1[|||||||||||             17.8% 5209MHz 34°C]   5[|||||         8.7% 5199MHz N/A]
```

**Frequency works. Per-core temperature does not, and cannot.** `k10temp` on this CPU exposes exactly two sensors:

```
temp1_label: Tctl     # package
temp3_label: Tccd1    # CCD die
```

There are no per-core thermal sensors on AMD — the die reports one package temperature, not eight. htop's per-core temperature display is effectively an Intel `coretemp` feature; here it maps the one reading it finds onto a single arbitrary core and prints `N/A` for the other seven.

`btop` (already installed at `/usr/bin/btop`) looks better — it shows a temperature against every core with no `N/A` — but it is printing the *same package number* eight times. It is not more information, only a tidier presentation of the same single sensor.

So, for temperature, the options in increasing order of usefulness:

- Turn `show_cpu_temperature` off in htop; it only adds `N/A` noise across most of the row.
- `watch -n1 sensors` for the actual `Tctl` / `Tccd1` values.
- **CoolerControl** on port 11987 — the only one of these that plots temperature over time. Off by default; `coolercontrol on` starts it for a measurement session. See [hardware/coolercontrol/](../../hardware/coolercontrol/README.md).

For **frequency**, htop's Text meter mode (`column_meter_modes` entry `2` instead of `1`) is far more legible than the bar:

```
0: 13.2% sys: 7.9% low: 0.0% vir: 0.0% freq:  964MHz temp:N/A
```

It costs the bar graph and a lot of horizontal width, which is a fair trade on a TV but not in a small terminal. Note that CPU frequency readings on AMD derive from APERF/MPERF and only tick in C0 — see [system/power/](../power/README.md) for why an apparently pinned 5.2 GHz at idle is not what it looks like.

## Note: SMT is off

`nproc` reports 8 on a Ryzen 7 9800X3D, which is an 8-core/16-thread part, and `/sys/devices/system/cpu/smt/control` reads `notsupported` — the kernel's answer when SMT is disabled in firmware. htop therefore shows 8 CPU meters, not 16. Unrelated to htop config; recorded here because it is the obvious thing to wonder about when looking at the header. Worth checking in BIOS if the missing threads are not deliberate.
