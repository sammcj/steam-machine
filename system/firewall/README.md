# Firewall — inbound IPv6

Blocks unsolicited inbound IPv6 from outside this LAN. IPv4 is untouched.

## The hole

SteamOS ships the `public` zone like this:

```
$ firewall-cmd --zone=public --list-ports
1024-65535/tcp 1024-65535/udp
```

Identical in runtime *and* permanent config, and firewalld port entries carry no
address-family restriction — so it applies to IPv6 exactly as much as IPv4.

For IPv4 that is survivable: the machine is on RFC1918 behind NAT, so nothing
reaches those ports without an explicit forward. For IPv6 it is not. This box
holds a **globally routable** address (verified — Python's `ipaddress` reports
`is_global=True` for both the DHCPv6 `/128` and the SLAAC address) and has a
default route via RA. Every listening service above port 1024 is exposed to
whatever the upstream router forwards. Steam alone holds several such ports, and
`system/rustdesk/` adds 21118.

**Not verified here:** whether the router actually forwards unsolicited inbound
IPv6. That needs an external vantage point. Most consumer routers default to
blocking it — but "most" and "default" are doing real work in that sentence, and
the host should not be relying on them.

## What it does

Rich rules on the default zone:

```
priority -100  family ipv6  source <each LAN prefix>  accept
priority    0  family ipv6  source ::/0               drop
```

Lower priority values take precedence, so the accepts are evaluated before the
drop. Nothing references IPv4, and nothing references port 22 — SSH from the
LAN keeps working through the prefix accepts.

The `source ::/0` on the drop is required, not stylistic: firewalld rejects a
bare `rule family="ipv6" drop` with `INVALID_RULE: no element, no source, no
destination`. Confirmed against firewalld 2.3.1's own `Rich_Rule` parser while this was being written -- the script does not re-check at runtime.

**Outbound-initiated traffic is unaffected.** firewalld's `filter_INPUT` accepts
`ct state established,related` before any zone rule, so replies to connections
this machine opened never reach the drop. That is not assumed: `assert_conntrack()`
greps the live nftables chain and **refuses to install the drop rule** if the
conntrack accept is not there.

### What counts as "this LAN"

Derived at apply time from both the interface's addresses *and* the on-link
prefixes the router advertises. Reading routes as well as addresses matters —
the RA-advertised ULA `fd50:fdf7:233::/64` has no address on this interface and
would be missed otherwise.

`/128` prefixes are skipped: SLAAC hands one out for the DHCPv6 address, and
allowing it would permit exactly one host — this one.

**Link-local and unique-local are generalised to `fe80::/10` and `fc00::/7`**
rather than pinned to whatever `/64` is configured today. That is not tidiness.
pfSense renumbered the ULA on this network — `fd50:fdf7:233::/64` became
`fde4:ff5:dc44:476e::/64` — and the rules, pinned to the old prefix, silently
began dropping LAN traffic on the new one. Neither range is routable on the
internet, so allowing the whole of each costs nothing: packets with those source
addresses cannot reach this machine from outside.

### The GUA is the one that can still bite

The globally-routable prefix cannot be generalised — allowing all of `2000::/3`
would defeat the entire point — so it stays pinned to whatever is live. If the
ISP re-delegates, that rule goes stale and **inbound SSH over IPv6 stops
working**, on a machine whose only other console is a TV.

That is why `--boot` *reconciles* rather than merely restoring: it compares the
desired rule set against what is installed and rewrites when they differ, so a
renumber self-corrects on the next boot. Recovery from a mid-session renumber is
therefore a reboot, or reaching the box over IPv4.

The **globally-routable** prefix is never written into this repo, which is public — it is derived at runtime and only ever appears in live `--status` output. The ULAs above are a deliberate exception: they are `fc00::/7`, not routable from anywhere off this LAN, and naming the two the network actually used is what makes the renumbering story legible.

### ICMPv6

Deliberately no blanket ICMPv6 allow, which would let the box be pinged from the
internet. The two cases that actually matter are covered anyway:

- **NDP / RA / DHCPv6** — sourced from link-local, covered by `fe80::/10`.
- **PMTUD "packet too big"** — arrives as conntrack `related`, so it is accepted
  before the zone rules. Dropping these is the classic way to produce IPv6
  connections that establish and then hang on the first large transfer.

## Applying it safely

This can lock you out of the only remote path into a machine whose only other
console is a TV in the living room. So `--apply` writes **runtime-only** rules
and arms an auto-revert first:

```bash
sudo ./install.sh --apply     # live for 5 minutes, then undone automatically
# ... confirm you are still connected, and open a second session ...
sudo ./install.sh --commit    # make permanent, cancel the revert
```

If it locks you out, **do nothing**. `firewall-cmd --reload` fires on a timer and
reinstates the permanent config, which at that point still has no IPv6 rules.

`--revert` removes them from both runtime and permanent config.

## Persistence

`/etc/firewalld` is **not** on SteamOS's keep list, so the permanent rules are
expected to vanish on an A/B update. Allowlisting `public.xml` would be the
wrong fix — it is a file firewalld and SteamOS both own, and pinning this
machine's copy would freeze it against every future upstream change.

Instead `steam-machine-firewall.service` re-applies them at boot when it finds
them missing. The unit lives in `/etc/systemd/system`, which *is* keep-listed.
The failure it prevents is silent: nothing breaks when the rules disappear, the
machine just quietly starts accepting inbound IPv6 again.

## Known gap

A manual `firewall-cmd --reload` reinstates permanent config, so once
`--commit` has run the rules survive it. Before `--commit` they do not — that is
exactly the property `--apply` relies on for its escape hatch.

## Consequence worth knowing

This blocks **all** unsolicited inbound IPv6, including SSH from outside the
LAN. Nothing is lost today — that path is not in use, and reaching this machine
from outside currently depends on the router forwarding IPv6 anyway. But if
remote SSH over IPv6 is ever wanted, it needs an explicit carve-out:

```bash
sudo firewall-cmd --permanent --zone=public --add-rich-rule \
  'rule priority="-100" family="ipv6" source address="<your-remote-prefix>" service name="ssh" accept'
```

Wake-on-LAN is unaffected — magic packets are layer 2 and arrive over IPv4
broadcast, nowhere near this.
