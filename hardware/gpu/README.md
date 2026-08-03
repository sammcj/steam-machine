# GPU — keeping AMD overdrive alive across SteamOS updates

All of this was verified on-machine on 2026-08-02, not inferred.

## What this is for

LACT (`io.github.ilya_zlobintsev.LACT`, Flatpak, with `lactd.service` running as
root) can only expose clock, voltage, power-limit and fan controls when `amdgpu`
is loaded with the **PP_OVERDRIVE** bit (`0x4000`) set in `ppfeaturemask`. Its
"enable overclocking" button writes:

```
/etc/modprobe.d/99-amdgpu-overdrive.conf
    options amdgpu ppfeaturemask=0xFFF7FFFF
```

That is the stock mask on this box (`0xFFF7BFFF`) with bit 14 set — nothing
else changes.

It works, and then a SteamOS update silently deletes it. `/etc/modprobe.d` is
not on the A/B keep list, so LACT's controls go back to greyed-out and the only
symptom is LACT offering to enable overclocking again as if it had never been
done.

**This is not hypothetical.** SteamOS snapshots `/etc` immediately before
discarding it, and the file was recovered from the snapshot taken by the update
on 1 Aug 2026:

```
$ tar tf /var/lib/steamos-atomupd/etc_backup/2026-08-01_21-38-35.tar.xz | grep modprobe
etc/modprobe.d/
etc/modprobe.d/99-amdgpu-overdrive.conf
```

That tarball contains exactly one file, and it is this one — every other
`/etc/modprobe.d` entry on the machine was already allowlisted by another
subsystem here. Overdrive was the one thing nobody had covered.

## What gets installed

| File | Purpose |
| --- | --- |
| `/etc/modprobe.d/99-amdgpu-overdrive.conf` | the module parameter itself (same path and bytes LACT writes) |
| `/etc/atomic-update.conf.d/steam-machine-gpu.conf` | allowlists the above so an A/B update carries it over |
| `/etc/systemd/system/steam-machine-gpu.service` | boot self-heal, in case the allowlist entry itself was ever missing when an update ran |

```
./install.sh              install all three, enable the unit
./install.sh --boot       self-heal only (what the unit runs)
./install.sh --status     report state
./install.sh --uninstall  remove all three; reboot drops back to stock
```

Root is needed: `SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh`.

## Details worth knowing

**The repo copy is byte-identical to LACT's.** No comment header, deliberately.
LACT rewrites that file whenever its overdrive toggle is flipped, and a comment
header would make every `cmp` report drift that isn't drift.

**`--boot` restores the file only when it is _missing_, never when it merely
differs.** LACT owns the content. If a future LACT picks a different mask,
fighting it on every boot would be a silent, confusing loss; a missing file, on
the other hand, has exactly one cause. `--status` reports a difference rather
than acting on it.

**Turning overdrive off means `--uninstall`, not just the LACT toggle.** If you
untick it in LACT, LACT deletes the file and the next boot's self-heal puts it
back. That is the whole point of the self-heal and it cannot tell your intent
from an OS update's.

**The boot after an update still has no overdrive.** `amdgpu` loads in early
userspace and its parameters are read-only afterwards
(`/sys/module/amdgpu/parameters/*` is mode `0444`), so a unit running at
`multi-user.target` is far too late to affect the boot it runs on. The self-heal
makes the *next* boot right without anyone having to notice the loss. In
practice the allowlist entry means this path should never fire at all.

**LACT's initramfs regeneration is a no-op here, twice over.** LACT runs
`mkinitcpio` after writing the file, on the assumption that `amdgpu` loads from
the initramfs. On this machine it does not — the image contains
`etc/modprobe.d/` but no `amdgpu.ko`, so `/etc/modprobe.d` is read at real
module load:

```
$ lsinitcpio /boot/initramfs-linux-neptune-616-drm-exec.img | grep -E 'amdgpu\.ko|modprobe\.d/'
etc/modprobe.d/
etc/modprobe.d/99-amdgpu-overdrive.conf
etc/modprobe.d/amdgpu-display.conf
...
```

And even if it did matter, `/boot` is on the A/B rootfs (`/dev/nvme0n1p5`, no
separate mount), so a regenerated initramfs is thrown away by the same update
that eats the config. `install.sh` warns if `amdgpu.ko` ever does appear in the
initramfs, since that would change the answer.

## Checking it

```
$ cat /sys/module/amdgpu/parameters/ppfeaturemask
0xfff7ffff        # bit 14 set -> LACT controls live
0xfff7bfff        # bit 14 clear -> stock; either not applied yet, or wiped
```

`./install.sh --status` does this and the rest of it, and calls out
"config asks for overdrive but the running kernel does not have it" when a
reboot is outstanding.

## Related

- Overclocking itself is still (L) on the TODO — this only makes the controls
  *available*, no clocks or limits are set here.
- `amdgpu` module parameters for the display path live in
  [hardware/display/](../display/README.md), in a separate `modprobe.d` file
  with its own keep entry. Two files rather than one because that one is ours
  outright and this one is LACT's.
