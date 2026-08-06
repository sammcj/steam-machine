# Secondary game library — BTRFS RAID1

The two Crucial MX500 2 TB SATA SSDs, mirrored, mounted at `/home/deck/SATA`
and usable as a second Steam library.

**Status: temporarily masked (2026-08-07)** while the power-off hang is being
bisected — see [Temporarily disabled for the power-off hang](#temporarily-disabled-for-the-power-off-hang)
below for how to put it back. Otherwise: mounted and surviving remount, with one
manual step remaining — see [Registering with Steam](#registering-with-steam).

## Temporarily disabled for the power-off hang

The array is unmounted and its generated mount unit is masked:

```bash
sudo systemctl mask home-deck-SATA.mount     # /etc/systemd/system/home-deck-SATA.mount -> /dev/null
sudo umount /home/deck/SATA
```

To restore:

```bash
sudo systemctl unmask home-deck-SATA.mount
sudo systemctl daemon-reload
sudo mount /home/deck/SATA
```

Masking rather than editing `/etc/fstab` is deliberate: `install.sh --boot`
re-adds the fstab entry every boot, so a commented-out line would come back. The
mask outranks the generator and needs no change to this subsystem. It also
persists correctly — `/etc/systemd/system/*.mount` is on the SteamOS keep list,
so the mask survives an A/B update as well as a reboot.

**Note that the evidence is against this array being the cause.** It has been in
`/etc/fstab` since 2026-08-03, so it was mounted during the two *successful*
power-offs on 2026-08-06 (17:39 and 17:59) as well as during both hangs. It also
holds 160 KiB — the array is effectively empty, so there is nothing to flush.
The test costs nothing, which is the only reason to run it. See
[hardware/kernel/](../kernel/README.md) under "OPEN: power-off hangs".

> **Move completed (2026-08-02).** The mount point moved from `/home/deck/Games`
> to `/home/deck/SATA`. The subvolume (`@games` → `@SATA`) and the filesystem
> label (`games` → `SATA`) were renamed to match, so nothing about this array
> is called "games" any more — the name only ever described what was on it, and
> it now collides with a real directory.
>
> **`/home/deck/Games` is not a leftover mount point — do not delete it.** It is
> an ordinary directory on the boot NVMe holding games moved off this array.
> The two are unrelated storage that happen to have had similar names.

| | |
| --- | --- |
| Devices | `/dev/sda`, `/dev/sdb` (whole-disk, no partition table) |
| UUID | `ae6c1cf6-9aa0-42d6-8745-28e5d05a12dd`, label `SATA` |
| Profile | `RAID1` for data, metadata **and** system |
| Usable | 1.82 TiB |
| Subvolume | `@SATA` |
| Mount | `/home/deck/SATA` |

## SteamOS will not automount this, by design

Worth knowing before trying to make the stock path work.
`/usr/lib/hwsupport/steamos-automount.sh` is hard-wired to ext4:

```bash
# We need symlinks for Steam for now, so only automount ext4 as that'll Steam will format right now
if [[ ${ID_FS_TYPE} != "ext4" ]]; then
    echo "Error mounting ${DEVICE}: wrong fstype: ${ID_FS_TYPE}"
    exit 2
```

It is also per-device (`sdb1`-style), which is the wrong shape for a two-device
array. So this uses a normal fstab entry, and Steam is pointed at the result as
a library folder. Functionally identical from the Deck UI's side: Settings →
Storage lists library folders, not block devices.

## One filesystem, one mount point

The array is hidden from udisks by
`/etc/udev/rules.d/60-steam-machine-storage.rules`, so it does **not** appear in
Dolphin's device list. fstab mounts it; there is nothing to click.

That is deliberate. Clicking it mounts the *top level* subvolume (`subvolid=5`)
at `/run/media/deck/SATA`, next to the fstab mount of `@SATA` — and then every
file is reachable by two paths that nothing on the system knows are the same
storage:

```
/home/deck/SATA/<game>
/run/media/deck/SATA/@SATA/<game>      # same bytes, different path
```

On 2026-08-02 this produced *three* simultaneous mounts (`games`, `games1`,
`games2`). udisks mounts per device, so a two-device array offers it the same
filesystem twice and it appends a suffix on each name collision. It could not
clean any of them up afterwards — it attributes the mount to `/dev/sdb` while
`/proc/mounts` names `/dev/sda`, because multi-device btrfs is outside its
model:

```
udisksd: Cleaning up mount point /run/media/deck/games (device 8:16 is not mounted)
udisksd: Error cleaning up mount point /run/media/deck/games: Device or resource busy
```

`install.sh --status` reports `extra mounts:` for exactly this. To get at the
top-level subvolume deliberately (which is how the `@SATA` rename was done),
mount it somewhere temporary and unmount it again:

```bash
sudo -A mount -o subvolid=5 UUID=ae6c1cf6-… /run/sata-top
```

## Mount options

```
UUID=ae6c1cf6-… /home/deck/SATA btrfs \
  noatime,compress=zstd:1,discard=async,space_cache=v2,subvol=@SATA,commit=120,nofail,x-systemd.device-timeout=15s 0 0
```

| Option | Why |
| --- | --- |
| `noatime` | Games do enormous numbers of reads; atime updates are pure write wear for nothing. |
| `compress=zstd:1` | Cheapest useful level. Btrfs detects incompressible extents and stores them raw, so precompressed game assets cost almost nothing while text, configs, shaders and Proton prefixes compress well. Higher levels burn CPU that a game wants. |
| `discard=async` | Queued TRIM. Synchronous `discard` stalls on large deletes — uninstalling a 150 GB game is exactly that case. |
| `space_cache=v2` | Free-space tree. The v1 cache has known scaling problems on large filesystems. |
| `commit=120` | 4× the default 30 s between commits — fewer metadata writes on a volume that is overwhelmingly reads. **Widens the power-cut loss window to 2 min**, which is the right trade for re-downloadable game installs and the wrong one for save data. Saves live in `/home`, which keeps the default. |
| `nofail` | This machine's only display is a TV. Dropping to an emergency shell it cannot render is worse than booting without the library. |
| `ssd` | Not specified — the kernel sets it automatically from `rotational=0`. |

Deliberately **not** used:

- **`autodefrag`** — write amplification on exactly the large files it would be
  defragmenting, and it fights `compress`. Wrong for a game library.
- **`nodatacow`** — would disable checksums, and checksums are the entire reason
  a RAID1 can repair itself rather than just detect a difference. It also
  silently disables compression.
- **`degraded`** — never as a permanent mount option. If a disk drops out, the
  array should fail to mount and say so, not quietly run unmirrored for months.
  Mounting degraded is a deliberate manual act; the command is in
  `bin/storage-report.sh`'s output.

### The `nofail` hazard, and the guard against it

`nofail` means a failed mount leaves an ordinary empty directory at
`/home/deck/SATA` — which Steam will cheerfully install into, silently filling
the 2 TB boot NVMe while appearing to work perfectly.

So the directory *underneath* the mount is `root:root 0555`. If the mirror
does not come up, Steam gets `EACCES` and reports an error instead. The
subvolume root mounted on top is `deck:deck 0755`. Verified both ways.

## Maintenance

| Unit | Schedule | Why |
| --- | --- | --- |
| `btrfs-scrub@home-deck-SATA.timer` | monthly | **The important one.** Btrfs only notices a bad copy when something reads it, and game files sit untouched for months. Scrub reads every block, verifies checksums, and repairs from the good mirror. A RAID1 that is never scrubbed is a RAID1 that rots quietly. |
| `fstrim.timer` | weekly | Belt and braces alongside `discard=async`, which can fall behind under sustained deletes. |
| `steam-machine-dedupe.timer` | monthly | See below. |
| `steam-machine-storage.service` | every boot | Restores the fstab entry and udev rule if a SteamOS update dropped them — see [Persistence](#persistence). No-op otherwise. |

Check health with `bin/storage-report.sh` — capacity, per-device error counters
(read/write/flush/**corruption**/generation, persistent across reboots), last
scrub result, and timer state.

## Dedupe — scoped on purpose

You asked for dedupe, so it is here and enabled, but the honest expectation is
**single-digit GB on a 1.82 TiB volume**, and run naively it would cost read
performance. Btrfs has no in-kernel dedupe; this is an out-of-band
`duperemove` pass. The return breaks down very unevenly:

- **Game assets — near zero, and actively harmful.** Titles ship precompressed,
  unique data. There is nothing to match, and deduping splits the large
  sequential extents that determine level load times.
- **Proton prefixes (`steamapps/compatdata`) — worthwhile.** One per game,
  ~0.5–1 GB each, and every one is a near-identical tree of Windows DLLs.
- **Shader caches (`steamapps/shadercache`) — worthwhile**, same reason, and
  fragmentation there is harmless because they are read in small random chunks
  anyway.

So `bin/dedupe.sh` runs over `compatdata` and `shadercache` only, at
`ionice -c3 nice -n19`, monthly. `--all` widens it to the whole volume if you
want to measure it yourself; `--dry-run` reports without changing anything.

**`compress=zstd:1` is doing far more for you than dedupe is**, and it costs
nothing ongoing. If you only keep one, keep the compression.

`duperemove` comes from pacman, so an A/B update deletes it. Rather than carry
a boot unit for that, `dedupe.sh` reinstalls it on demand — the timer is
monthly, so one pacman call a month is cheap.

## Registering with Steam

The mount is automatic; telling Steam about it is a one-time action, and it
**cannot be done while Steam is running** — Steam holds `libraryfolders.vdf`
in memory and rewrites it on exit, discarding outside edits.

Either:

- **Desktop mode** — Steam → Settings → Storage → `+` → `/home/deck/SATA`.
  This is what Steam itself does; nothing can go wrong.
- **Scripted**, with Steam fully closed:
  ```bash
  ./bin/steam-add-library.sh          # backs up the vdf, validates the edit
  ./bin/steam-add-library.sh --check  # status only
  ```

Afterwards it appears in Settings → Storage as a second drive, and the install
dialog offers a drive picker.

## Usage

```bash
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh              # full setup
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh --no-dedupe  # skip dedupe timer
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh --boot       # what the boot unit runs
./install.sh --status
./bin/storage-report.sh
./bin/dedupe.sh --dry-run
```

`install.sh --uninstall` unmounts and removes the fstab entry and timers. It
never touches the filesystem or anything on it.

## Persistence

Everything here is in `/etc`, which is an overlayfs with its upper layer in
`/var` — so it all survives reboots unconditionally. **A SteamOS A/B update is
a different matter**: since 3.6 only an allowlisted subset of `/etc` carries
into the new image (`/usr/lib/rauc/atomic-update-keep.conf`), and two files
this subsystem depends on are not on it:

| File | On the keep list? | Covered by |
| --- | --- | --- |
| `/etc/systemd/system/*.service`, `*.timer` wants | yes | — |
| `/etc/udev/rules.d/60-steam-machine-storage.rules` | **no** | `atomic-update.conf.d/steam-machine-storage.conf` **and** `--boot` |
| `/etc/fstab` | **no** | `--boot` only |

Losing the fstab entry means the library simply does not mount — with `nofail`
there is no error, just an empty `/home/deck/SATA` that Steam cannot write to
(see [the `nofail` hazard](#the-nofail-hazard-and-the-guard-against-it)).

`/etc/fstab` deliberately gets **no** keep-list entry. Allowlisting a path
shadows every future upstream version of it, and fstab is a file SteamOS owns
and reshapes across releases (partsets, `/efi`, `/esp`). Pinning this machine's
copy would quietly block all of that. So `steam-machine-storage.service` runs
`install.sh --boot` at every boot, which re-adds the entry if it is missing and
does nothing if it is not.

A restored entry does not mount anything that boot — it applies at the next
one. Remounting underneath a running session is the worse failure on a machine
whose only display is a TV.

The other update casualty is the `duperemove` binary, which `dedupe.sh`
reinstalls itself.

Verified by unmounting and remounting through the fstab entry rather than by
reboot, and by simulating an update — stock fstab, rule and keep entry deleted,
then `--boot`, which restored all three and remounted clean. A second `--boot`
was a no-op.

## If a disk fails

1. `bin/storage-report.sh` — a non-zero `corruption_errs` or `read_io_errs` on
   one device, with the array still readable, means the mirror is doing its job.
2. Do **not** add `degraded` to fstab. Mount it manually, read-only, to get data
   off:
   ```bash
   sudo -A mount -o degraded,ro UUID=ae6c1cf6-9aa0-42d6-8745-28e5d05a12dd /home/deck/SATA
   ```
3. Replace, then `btrfs replace start <devid> /dev/sdX /home/deck/SATA`,
   followed by a scrub.

Everything on here is re-downloadable, so the mirror is about avoiding a
150 GB re-download and catching a dying drive early — not about backup.
Nothing irreplaceable should live on it.
