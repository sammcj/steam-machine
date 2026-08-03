# Onboard MediaTek MT7902 Bluetooth

Gets the motherboard's built-in Bluetooth radio working on SteamOS 3.8
(kernel 6.16), which has no driver for it.

**Status: working.** `hci0` = onboard MT7902 with a real BD_ADDR (`hciconfig hci0` prints it), and BlueZ uses it as the default controller.

## The problem

The Gigabyte B850M FORCE WIFI6E V2 carries a **MediaTek MT7902** (Filogic 310).
It presents as two independent devices:

| Function  | Device                | Status                    |
| --------- | --------------------- | ------------------------- |
| Bluetooth | USB `0e8d:7902`       | **fixed here**            |
| Wi-Fi     | PCIe `14c3:7902`      | still unsupported         |

Mainline support for both landed in **kernel 7.1**; SteamOS 3.8 is on 6.16.

On a stock system the in-tree `btusb` matches the USB device via its generic
Bluetooth-class entry, hands it to `btmtk`, and `btmtk` rejects it:

```
Bluetooth: hci1: Unsupported hardware variant (00007902)
```

`hci1` is then left permanently `DOWN` with BD address `00:00:00:00:00:00`.
`btmtk` in 6.16 only knows MT7922 / MT7961 / MT7925, and `linux-firmware` ships
no `BT_RAM_CODE_MT7902_*` blob.

## The fix

An out-of-tree `btusb_mt7902.ko`, built from
[hmtheboy154/mt7902](https://github.com/hmtheboy154/mt7902) branch
`bluetooth_backport` (a backport of MediaTek's kernel 7.1 patches), plus the
`BT_RAM_CODE_MT7902_1_1_hdr.bin` firmware that branch ships.

Upstream needed three local changes (`patches/`, already applied to
`upstream/`) — the first is a genuine functional gap, the other two are needed
to coexist with the in-tree driver:

1. **`0001` — add `0e8d:7902` to `quirks_table`, narrow `btusb_table`.**
   Upstream's quirks table only lists `13d3:3579/3580/3594/3596` and
   `0e8d:1ede`, and unlike mainline it has no vendor-wide `0x0e8d` match. Our
   exact device was therefore never assigned `BTUSB_MEDIATEK`, so
   `btusb_mtk_setup()` never ran and the new `case 0x7902:` in `btmtk.c` was
   dead code. The same patch cuts `btusb_table` down to `0e8d:7902` **only**,
   removing the generic Bluetooth-class match, so this module can never claim
   the Realtek USB dongle or any other adapter — it has no Realtek/Intel/
   Broadcom support compiled in.
2. **`0002` — un-export `btmtk`'s symbols.** `btmtk.o` and `btusb.o` are linked
   into one module here, so the exports are redundant and collide with the
   in-tree `btmtk`, which stays loaded to serve the dongle:
   `btusb_mt7902: exports duplicate symbol alloc_mtk_intr_urb (owned by btmtk)`.
3. **Rename the `usb_driver` to `btusb_mt7902`** (in `0001`). usbcore refuses a
   second driver registering the name `btusb`:
   `Error: Driver 'btusb' is already registered, aborting...`.

The in-tree `btusb`/`btmtk` stay loaded and keep serving every other adapter.

## Layout

```
install.sh                     build / install / boot-restore / status / uninstall
upstream/                      vendored driver source (patches ALREADY applied) + firmware
upstream/UPSTREAM_COMMIT       exact upstream commit this was taken from
upstream/README.md             upstream's own readme, kept as-is
patches/                       our diffs vs pristine upstream, for provenance
systemd/mt7902-bt.service      restores the driver after a SteamOS update
modprobe.d/mt7902-bt.conf      softdep so our module loads before btusb
atomic-update.conf.d/          allowlists the above so an A/B update keeps it
```

`upstream/` is vendored **with our patches already applied**, so the build has
no patch step that could fail at boot. `patches/` is the record of what we
changed, not something the build applies.

To re-derive them against a fresh upstream checkout — note SteamOS has no
`patch(1)`, so use `git apply`:

```bash
BT=$(pwd)                      # this directory (hardware/bluetooth)
git clone -b bluetooth_backport https://github.com/hmtheboy154/mt7902 /tmp/mt7902
cd /tmp/mt7902
git checkout "$(head -1 "$BT/upstream/UPSTREAM_COMMIT")"
git apply -p1 "$BT"/patches/000*.patch
diff -r src "$BT/upstream/src"   # should report no differences
```

Verified: applying both patches to the pristine upstream at
`UPSTREAM_COMMIT` reproduces `upstream/src/` byte-for-byte.

## Usage

```bash
sudo ./install.sh              # full install (idempotent)
./install.sh --status          # what's loaded, bound and up
sudo ./install.sh --uninstall  # remove module, firmware and boot service
```

`--status` needs no root. `sudo` cannot prompt from a non-TTY shell here, so
use the graphical askpass (pops a dialog on the TV):

```bash
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./install.sh
```

`install.sh` does everything from a clean machine — there are no manual
prerequisites. In order it: initialises the pacman keyring, unlocks the
read-only rootfs, installs the matching kernel headers plus `gcc`/`make`,
builds the module, installs it with the firmware, installs the modprobe and
systemd config, and binds the device.

Two of those steps are SteamOS-specific and easy to trip over by hand:

- **The pacman keyring is uninitialised out of the box** — SteamOS isn't meant
  to install packages this way. Without `pacman-key --init && pacman-key
  --populate archlinux holo`, `pacman -Sy` fails with `required key missing
  from keyring`. The script does this itself, and detects an already-populated
  keyring by counting keys (`pubring.gpg` here is a 0-byte legacy stub — the
  real keyring is `pubring.kbx`, so testing for that file is misleading).
- **The rootfs must be writable** (`steamos-readonly disable`). The script
  unlocks it and restores whatever state it found.

The kernel headers must match the running kernel exactly. The script derives
the package name from `/usr/lib/modules/$(uname -r)/pkgbase` rather than
hardcoding it — currently `linux-neptune-616-drm-exec-headers`.

## How it survives updates and reboots

SteamOS replaces the entire `/usr` tree on every A/B update, deleting both the
module and the firmware. So nothing authoritative lives there:

- **Source and firmware** live in this repo (on `/home`, its own partition).
- **The built module** is cached at
  `~/.cache/mt7902-bt/modules/<kernel-version>/`, keyed by kernel version and
  by a hash of the source (so editing `upstream/` invalidates a stale build).
- **`mt7902-bt.service`** runs at each boot and calls `install.sh --boot`:
  - `/usr` intact → binds the device and exits (~20 ms).
  - `/usr` wiped, same kernel → reinstalls from cache. **Offline, ~0.7 s.**
  - Kernel version changed → reinstalls headers/toolchain via pacman and
    rebuilds. Needs the network; retries 5 × 30 s.

Verified by deleting the module and firmware from `/usr`, unloading the module,
and running the boot path: full recovery in 0.66 s with no network.

### `/etc` and the atomic-update keep list

An earlier version of these notes said `/etc` "normally persists" across
updates. That was too optimistic, and the gap was real (found 2026-08-02).

Since SteamOS 3.6 only an **allowlisted subset** of `/etc` carries into a new OS
image. The default list is `/usr/lib/rauc/atomic-update-keep.conf`:

- `/etc/systemd/system/*.service` and `/etc/systemd/system/*.wants/**` **are**
  on it, so `mt7902-bt.service` and its enable symlink survive by themselves.
- **`/etc/modprobe.d` is not.** So `mt7902-bt.conf` — carrying the
  `softdep btusb pre: btusb_mt7902` that stops the in-tree `btusb` claiming the
  device first — was being dropped on every A/B update. Worse, neither path
  through `do_boot()` restored it: the fast path exits early once the module and
  firmware check out, and the post-update path only reinstalls the module and
  firmware.

Two fixes, both in place:

1. `atomic-update.conf.d/steam-machine-bluetooth.conf` allowlists the specific
   file (not the directory — an allowlisted path shadows all future upstream
   versions of it forever). `/etc/atomic-update.conf.d/*.conf` is itself on the
   default keep list, so the entry preserves itself.
2. `ensure_system_config()` runs **before** the fast-path exit in `do_boot()` and
   reinstalls either file if it is missing or modified. Cheap, idempotent, and
   needs no `unlock_rootfs` — `/etc` is an overlayfs with its upper layer in
   `/var`, writable even when `steamos-readonly` is enabled.

Verified by deleting `/etc/modprobe.d/mt7902-bt.conf` and running
`install.sh --boot`: restored byte-identically, and `modprobe -c` parses the
softdep again.

`./install.sh --status` now reports both.

### Caveats

- The failure mode above was **degradation, not a hard break**: `bind_device()`
  explicitly unbinds the device from whatever claimed it and rebinds it to
  `btusb_mt7902`, so Bluetooth would usually still come up. The softdep is the
  first line of defence, and losing it widens the window in which `btusb` owns
  the device and logs `Unsupported hardware variant (00007902)`.
- **Keep the USB dongle.** It is the fallback and costs nothing to leave in.
  If anything here fails, the worst case is the pre-existing behaviour plus a
  working dongle.
- **A kernel change means a rebuild**, which needs the network at boot. It is
  the one path that is not fast or offline, and the only one that depends on
  pacman (and therefore on the keyring) still being usable.
- The kernel is **tainted** (unsigned out-of-tree module). Harmless here.
- First-ever setup after a cold boot takes ~20 s (`Device setup in 20161425
  usecs`) while the 509 KB firmware uploads. Subsequent binds are ~1 s.

## Wi-Fi

Still not working, and not attempted — 2.5 GbE is wired. The
[`backport` branch](https://github.com/hmtheboy154/mt7902/tree/backport) of the
same repo builds `mt7902e.ko` for the PCIe side if it ever matters.

Revisit the whole thing when SteamOS rebases onto a 7.1+ kernel, at which point
all of this should be deleted in favour of the in-tree driver.
