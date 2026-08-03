#!/usr/bin/env bash
# Block unsolicited inbound IPv6 from outside this LAN.
#
#   ./install.sh --apply     apply RUNTIME rules with an auto-revert armed.
#                            Safe to test: if it locks you out, do nothing and
#                            the machine undoes it by itself.
#   ./install.sh --commit    keep them: write to permanent config, cancel revert
#   ./install.sh --revert    remove, runtime and permanent
#   ./install.sh --boot      restore permanent rules after a SteamOS update
#   ./install.sh --status
#
# Why this exists. SteamOS ships the `public` zone with 1024-65535/tcp AND /udp
# open wholesale, in both runtime and permanent config, with no address-family
# restriction -- so it applies to IPv6 as much as IPv4. This machine holds a
# globally routable IPv6 address (verified: Python's ipaddress reports
# is_global=True) and has a default route via RA. Every listening service above
# port 1024 is therefore exposed to whatever the upstream router forwards. That
# is a lot of surface for a living-room console: Steam alone holds several such
# ports, and hardware/../rustdesk adds 21118.
#
# IPv4 is deliberately untouched. It is RFC1918 behind NAT, so the same port
# range is not reachable from outside without an explicit forward.
#
# The rules are inbound-only and stateful: firewalld's INPUT path accepts
# ct state established,related BEFORE any zone rule, so anything this machine
# initiated keeps working. That ordering is not assumed -- assert_conntrack()
# checks it and refuses to install the drop rule if it is missing.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IFACE="${FW_IFACE:-enp9s0}"
REVERT_AFTER="${FW_REVERT_AFTER:-5min}"
REVERT_UNIT="steam-machine-firewall-autorevert"
UNIT="steam-machine-firewall.service"
UNIT_SRC="$REPO_DIR/systemd/$UNIT"
UNIT_DEST="/etc/systemd/system/$UNIT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"; }
zone() { firewall-cmd --get-default-zone 2>/dev/null || echo public; }

# Every IPv6 prefix that counts as "this LAN": addresses configured on the
# interface plus on-link prefixes the router advertises. The RA-advertised ULA
# has no address here but is still a legitimate LAN source, so routes are read
# as well as addresses.
#
# /128 is skipped -- SLAAC hands one out for the DHCPv6 address, and
# whitelisting it would allow exactly one host: this one.
lan6_prefixes() {
    {
        ip -o -6 addr show "$IFACE" 2>/dev/null | awk '{print $4}'
        ip -6 route show dev "$IFACE" 2>/dev/null | awk '$1 !~ /default|multicast/ {print $1}'
    } | python3 -c '
import sys, ipaddress
seen = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        net = ipaddress.ip_interface(line).network
    except ValueError:
        continue
    if net.version != 6 or net.prefixlen == 128 or net.is_multicast:
        continue
    # Normalise link-local and unique-local to their architectural ranges
    # rather than whatever /64 happens to be configured today.
    #
    # This is not tidiness. A router can renumber the ULA -- pfSense did
    # exactly that here, swapping fd50:fdf7:233::/64 for
    # fde4:ff5:dc44:476e::/64 -- and a rule pinned to the old prefix then
    # silently drops LAN traffic on the new one. Neither fc00::/7 nor
    # fe80::/10 is routable on the internet, so allowing the whole range
    # costs nothing: packets from those sources cannot reach us from outside.
    if net.subnet_of(ipaddress.ip_network("fe80::/10")):
        cidr = "fe80::/10"
    elif net.subnet_of(ipaddress.ip_network("fc00::/7")):
        cidr = "fc00::/7"
    else:
        cidr = str(net)
    if cidr not in seen:
        seen.append(cidr)
print("\n".join(seen))
'
}

# The globally-routable prefix is the one that cannot be generalised -- allowing
# all of 2000::/3 would defeat the point. So it stays pinned to whatever is
# live, and the cost is that an ISP re-delegation makes the rule stale.
#
# Comparing desired against actual, rather than merely checking presence, is
# what makes that recoverable: the boot unit re-derives and rewrites the rules
# every boot, so a renumber self-corrects on the next restart.
rules_match_live() {
    local want have
    want="$(rich_rules | sort)"
    have="$(firewall-cmd --permanent --zone="$(zone)" --list-rich-rules 2>/dev/null |
            grep -F 'family="ipv6"' | sort || true)"
    [[ "$want" == "$have" ]]
}

# The whole design rests on established/related being accepted before the zone
# chains. Verify rather than trust: without it, the drop rule below would cut
# every outbound-initiated connection, including the SSH session running this.
assert_conntrack() {
    local rules
    rules="$(nft list chain inet firewalld filter_INPUT 2>/dev/null || true)"
    [[ -n "$rules" ]] || die "cannot read the firewalld nftables chain -- is firewalld running?"
    if ! grep -Eq 'ct state .*(established|related).* accept' <<<"$rules"; then
        echo "$rules" >&2
        die "no 'ct state established,related accept' in filter_INPUT -- refusing to add a drop rule"
    fi
    log "verified: established/related is accepted ahead of the zone rules"
}

rich_rules() {
    local p
    while read -r p; do
        [[ -n "$p" ]] || continue
        printf 'rule priority="-100" family="ipv6" source address="%s" accept\n' "$p"
    done < <(lan6_prefixes)
    # Everything else inbound over IPv6. The explicit ::/0 source is required,
    # not stylistic: firewalld rejects a bare `rule family="ipv6" drop` with
    # `INVALID_RULE: no element, no source, no destination` -- confirmed against
    # firewalld 2.3.1's own Rich_Rule parser before this was written.
    #
    # The LAN accepts above sort ahead of this: lower priority values take
    # precedence, so -100 is evaluated before 0.
    printf 'rule priority="0" family="ipv6" source address="::/0" drop\n'
}

apply_rules() {
    local mode="$1" r n=0        # mode: "" for runtime, "--permanent"
    while read -r r; do
        [[ -n "$r" ]] || continue
        if firewall-cmd --quiet $mode --zone="$(zone)" --add-rich-rule "$r"; then
            n=$((n + 1))
        else
            warn "could not add: $r"
        fi
    done < <(rich_rules)
    log "applied $n rule(s) ${mode:-(runtime)}"
}

# No pipeline into grep here, deliberately. Under `set -o pipefail` a grep that
# matches nothing exits 1, fails the whole pipeline and -- with `set -e` -- kills
# the script. That is precisely the first-run case: nothing to remove yet. The
# match is done in bash instead, on a captured string.
remove_rules() {
    local mode="$1" r rules
    rules="$(firewall-cmd $mode --zone="$(zone)" --list-rich-rules 2>/dev/null || true)"
    [[ -n "$rules" ]] || return 0
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        [[ "$r" == *'family="ipv6"'* ]] || continue
        firewall-cmd --quiet $mode --zone="$(zone)" --remove-rich-rule "$r" || true
    done <<< "$rules"
}

do_apply() {
    need_root
    command -v firewall-cmd >/dev/null || die "firewalld not installed"
    systemctl is-active --quiet firewalld || die "firewalld is not running"
    assert_conntrack

    local prefixes; prefixes="$(lan6_prefixes | paste -sd' ' -)"
    [[ -n "$prefixes" ]] || die "could not derive any LAN IPv6 prefix -- refusing to continue"
    log "treating these as local: $prefixes"

    # Arm the escape hatch BEFORE touching anything. These are runtime-only
    # rules, so `firewall-cmd --reload` reinstates the permanent config and
    # undoes them wholesale. If this SSH session dies, do nothing for
    # $REVERT_AFTER and the machine lets you back in by itself -- the TV is the
    # only other console, and this box lives in the living room.
    systemctl stop "$REVERT_UNIT.timer" >/dev/null 2>&1 || true
    systemd-run --quiet --collect --on-active="$REVERT_AFTER" --unit="$REVERT_UNIT" \
        firewall-cmd --reload
    log "auto-revert armed: firewall-cmd --reload in $REVERT_AFTER"

    remove_rules ""
    apply_rules ""

    echo
    do_status
    cat <<EOF

Runtime rules are live and WILL BE UNDONE in $REVERT_AFTER.

  1. Check you are still connected, and open a SECOND ssh session to be sure.
  2. If it works:   sudo $REPO_DIR/install.sh --commit
  3. If it breaks:  do nothing. It reverts by itself.
EOF
}

do_commit() {
    need_root
    log "cancelling auto-revert"
    systemctl stop "$REVERT_UNIT.timer" >/dev/null 2>&1 || true

    remove_rules "--permanent"
    apply_rules "--permanent"

    log "installing $UNIT_DEST (restores these after a SteamOS update)"
    install -Dm644 "$UNIT_SRC" "$UNIT_DEST"
    systemctl daemon-reload
    systemctl enable "$UNIT" >/dev/null 2>&1 || warn "could not enable $UNIT"

    # Safe now: permanent config carries the rules, so the reload reinstates
    # rather than removes them.
    firewall-cmd --reload >/dev/null 2>&1 || warn "reload failed"
    log "committed"
    echo
    do_status
}

# /etc/firewalld is NOT on SteamOS's keep list, and allowlisting the zone file
# would shadow every future upstream version of it -- so the permanent rules are
# expected to vanish on an A/B update. This puts them back. The unit lives in
# /etc/systemd/system, which IS keep-listed.
do_boot() {
    need_root
    systemctl is-active --quiet firewalld || return 0

    # Reconcile, do not merely restore. Checking only for presence would leave
    # rules pinned to a prefix the machine no longer has -- which drops LAN
    # traffic on the new one with no error anywhere.
    if rules_match_live; then
        return 0
    fi
    warn "IPv6 rules do not match the live prefixes -- rewriting"
    assert_conntrack
    remove_rules "--permanent"
    apply_rules "--permanent"
    firewall-cmd --reload >/dev/null 2>&1 || true
}

do_revert() {
    need_root
    systemctl stop "$REVERT_UNIT.timer" >/dev/null 2>&1 || true
    systemctl disable "$UNIT" >/dev/null 2>&1 || true
    rm -f "$UNIT_DEST"
    systemctl daemon-reload
    remove_rules ""
    remove_rules "--permanent"
    firewall-cmd --reload >/dev/null 2>&1 || true
    warn "reverted -- inbound IPv6 is open again above port 1024"
}

do_status() {
    printf 'default zone:           %s\n' "$(zone)"
    printf 'open ports (all famly): %s\n' "$(firewall-cmd --zone="$(zone)" --list-ports 2>/dev/null)"
    printf 'services:               %s\n' "$(firewall-cmd --zone="$(zone)" --list-services 2>/dev/null)"
    echo
    echo "LAN IPv6 prefixes treated as local:"
    lan6_prefixes | sed 's/^/  /'
    echo
    echo "runtime ipv6 rich rules:"
    firewall-cmd --zone="$(zone)" --list-rich-rules 2>/dev/null | grep -F 'family="ipv6"' | sed 's/^/  /' || echo "  (none)"
    echo "permanent ipv6 rich rules:"
    firewall-cmd --permanent --zone="$(zone)" --list-rich-rules 2>/dev/null | grep -F 'family="ipv6"' | sed 's/^/  /' || echo "  (none)"
    echo
    echo -n "auto-revert pending:    "
    systemctl is-active --quiet "$REVERT_UNIT.timer" 2>/dev/null \
        && systemctl show "$REVERT_UNIT.timer" -p NextElapseUSecRealtime --value \
        || echo "no"
    echo -n "boot restore unit:      "
    systemctl is-enabled --quiet "$UNIT" 2>/dev/null && echo "enabled" || echo "not enabled"
}

case "${1:-}" in
    --apply)     do_apply ;;
    --commit)    do_commit ;;
    --revert)    do_revert ;;
    --boot)      do_boot ;;
    ""|--status) do_status ;;
    *) die "unknown option: $1" ;;
esac
