# Network — Wake-on-LAN

Wake the machine from suspend or from full power-off with a magic packet.

## Starting state: not armed

WoL was not configured at all. Three independent confirmations:

| Check | Value |
|---|---|
| `/sys/class/net/enp9s0/device/power/wakeup` | `disabled` |
| `…/power/wakeup_count` | **empty** |
| `/proc/acpi/wakeup` | `LN00  S4  *disabled  pci:0000:09:00.0` |
| `nmcli … 802-3-ethernet.wake-on-lan` | `default` (NM leaves it alone) |

The empty `wakeup_count` is the crisp signal: those counters are backed by a
wakeup-source object that only exists once wakeup has been enabled. Empty means
*never enabled*, as distinct from `0` meaning *enabled, never fired*.

**Nothing arms WoL at boot by itself.** `r8169` only ever writes `saved_wolopts`
from the ethtool `SWOL` ioctl; at probe it does the opposite, calling
`rtl_set_d3_pll_down(tp, true)` so the PLL drops in D3. Userspace has to arm it
on every boot. That is what this subsystem does.

## The hardware

`RTL8125D` (XID 688) on in-tree `r8169`, kernel 6.16. In-tree support is
genuine — `rtl_is_8125()` is true for this chip, so it takes the 8125-specific
magic-packet path (`r8168_mac_ocp_modify(tp, 0xc0b6, 0, BIT(0))`) and the
`PME_SIGNAL` path. **Realtek's out-of-tree `r8125-dkms` is not needed**, and on
an immutable rootfs it would be actively worse — it needs rebuilding on every
kernel bump.

Unrelated but worth noting: the link negotiates **1 Gb/s, not 2.5**. That is the
cable or the switch port, not the driver.

## Why two mechanisms

Both issue the same `ETHTOOL_SWOL` ioctl that `ethtool -s wol g` would — which
matters, because `ethtool` is not installed and this needs no such thing.

**`.link` drop-in** — applied by udev's `net_setup_link` builtin at the `add`
event, which is why it works even though this machine runs NetworkManager and
not `systemd-networkd`. It arms WoL on every boot unconditionally, before NM
exists, whether or not any profile ever activates. That closes NM's known hole
where WoL is armed only after an activation (`Wake-on: d` after a plain reboot
but `g` after a suspend/resume cycle is a widely reported symptom).

**NetworkManager property** — survives SteamOS A/B updates for free, because
`/etc/NetworkManager/system-connections/*` is on the default keep list while
`/etc/systemd/network` is not. It also earns its place at suspend time: NM's
`nm-manager.c` skips the pre-suspend interface takedown for devices with WoL
armed, and its `device_is_wake_on_lan()` check reads `wolopts != 0`.

Belt and braces, and they cannot fight: NM at `default` issues no ioctl at all,
and NM at `magic` issues exactly what udev already did.

### Two traps avoided

**The drop-in is a drop-in, not a new `.link` file.** udev's `link_get_config()`
returns on the *first* matching file. A `10-wol.link` would displace
`99-default.link` entirely, taking `NamePolicy`, `AlternativeNamesPolicy` and
`MACAddressPolicy` with it — renaming `enp9s0` to `eth0` and breaking every NM
profile bound to the name, on the only interface this machine is reachable over.

**No WoL password, anywhere.** `rtl8169_set_wol()` does
`if (wol->wolopts & ~WAKE_ANY) return -EINVAL;`, and `WAKE_ANY` excludes
`WAKE_MAGICSECURE`. Setting a SecureOn password does not make WoL more
selective — it makes the whole ioctl fail so that *nothing* is armed.

## Do not touch `/proc/acpi/wakeup`

It is tempting, and it is wrong. Two reasons:

- **It is a readout, not a switch.** The `enabled`/`disabled` word is the logical
  OR of the ACPI device's and the physical PCI device's `device_may_wakeup()`.
  `r8169`'s `__rtl8169_set_wol()` ends in `device_set_wakeup_enable()`, so arming
  WoL flips the `LN00` line to `*enabled` on its own. (The `*` is unrelated to
  status — it only means the node has a valid `_PRW`.)
- **The write handler is a toggle, not a set.** `echo LN00 > /proc/acpi/wakeup`
  after WoL is configured turns it back *off*. It also does not persist across
  reboot — there is no backing store.

## BIOS — the part this cannot do

Wake from **S5** (full power off) additionally needs firmware cooperation:

**`Settings → Platform Power → ErP = Disabled`.**

ErP exists to get S5 draw under 1 W, and it achieves that by cutting the +5 V
standby rail that keeps the NIC alive. Gigabyte's own FAQ is explicit that
enabling it disables PME wake, wake-on-mouse, wake-on-keyboard and Wake on LAN.

Fastest field test, no BIOS trip needed: **after `systemctl poweroff`, the rear
LAN LED must stay lit.** Dark LED means ErP is still on. Expect the link to drop
to a lower speed — `rtl_prepare_power_down()` calls `phy_speed_down()`
deliberately — but it must not go out entirely.

Wake from S3 (suspend) does not depend on the standby rail the same way and
should work once `power/wakeup` reads `enabled`.

## Testing it remotely, without a one-way door

This machine's only console is a TV in the living room, so a failed wake test
from a remote session means waiting until someone can reach the power button.
Test **S3 first**, with an RTC alarm as a second, independent way back:

```bash
# 1. arm a 10-minute RTC backstop and confirm it took
sudo sh -c 'echo 0 > /sys/class/rtc/rtc0/wakealarm &&
            echo +600 > /sys/class/rtc/rtc0/wakealarm &&
            cat /sys/class/rtc/rtc0/wakealarm'

# 2. suspend. -i is required: hardware/sleep's keepawake daemon holds a
#    `block` inhibitor on sleep for as long as an SSH session exists, and
#    logind will otherwise refuse.
sudo systemctl suspend -i
```

Then, from another machine on the subnet — broadcast, never unicast, because
once the box is asleep its ARP entry expires and a unicast packet cannot be
addressed at all:

```bash
wakeonlan -i 192.168.0.255 <mac-from-install.sh---status>
```

**Which mechanism actually woke it** is worth knowing, and the NIC keeps score:

```bash
cat /sys/class/net/enp9s0/device/power/wakeup_count
```

It increments only on a wake sourced from that device. `1` means the magic
packet did it; still `0` means the RTC backstop fired and WoL did **not** work.
Without this check a successful-looking test proves nothing.

### The backstop does not cover the S5 test

`systemctl poweroff` has no remote safety net. RTC wake from S5 and WoL from S5
depend on the *same* +5 V standby rail that ErP cuts — so if ErP is still
enabled, both fail together and the machine stays off. There is also no `RTC`
entry in `/proc/acpi/wakeup` on this board, so the alarm is relying on the ACPI
fixed event rather than an enumerated wakeup device; usually fine, not
guaranteed.

Do the poweroff test when someone can physically reach the machine, or accept
that it may stay off until they can.

```bash
sudo ./install.sh            # install; arms at next boot
sudo ./install.sh --arm-now  # also re-trigger udev to arm immediately
./install.sh --status
```

The default deliberately does **not** arm immediately. `--arm-now` fires an
`add` uevent on the only interface this machine is reachable over; it should be
harmless, but a reboot is needed for the BIOS change anyway, so there is usually
nothing to gain by taking the risk.

The single check that matters is `power/wakeup`. Configuration files can all be
in place while the ioctl never landed:

```bash
cat /sys/class/net/enp9s0/device/power/wakeup   # want: enabled
```

`r8169` logs **nothing** on WoL configuration — verified by grepping the driver,
whose only `netdev_info` calls are the XID banner, jumbo features and DASH
state. Do not wait for a dmesg line that will never come.

## Sending the packet

From another machine **on this subnet**, to the **broadcast** address:

```bash
wakeonlan -i 192.168.0.255 <mac>      # ./install.sh --status prints the MAC
```

Unicast does not work once the machine is off: its ARP entry ages out, so the
sender cannot resolve a destination MAC and never builds the frame. This is the
single most common reason a working setup looks broken. Sending from the router
is the most reliable option of all, since it is on the target's L2 segment by
definition.

Worth pairing with a static DHCP lease for the NIC, so the broadcast address
stays predictable.
