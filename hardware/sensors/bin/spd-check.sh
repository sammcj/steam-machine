#!/usr/bin/env bash
# Early warning for DDR5 SPD corruption.
#
# This board has no hardware SPD write protection (see ../README.md), and
# enabling the FCH SMBus means the host can reach the SPD EEPROMs. A corrupted
# SPD shows up as changed size, speed, part number or serial in DMI long before
# the machine stops booting -- so compare against the baseline taken before the
# bus was ever exposed.
#
# dmidecode reads DMI tables from firmware memory. It generates zero bus
# traffic, so running this is always safe.
#
#   ./spd-check.sh            compare against the committed baseline
#   ./spd-check.sh --update   accept the current state as the new baseline
#                             (only after a deliberate RAM change)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$REPO_DIR/baseline/dmidecode-t17.txt"

SUDO=()
[[ $EUID -ne 0 ]] && SUDO=(sudo -A)

current() {
    SUDO_ASKPASS="${SUDO_ASKPASS:-/usr/bin/ksshaskpass}" "${SUDO[@]}" dmidecode -t 17
}

# The serials identify this specific pair of DIMMs and this repo is public, so they are never written to disk in the clear. Hashing keeps the canary intact -- a serial that changes still changes the digest -- without publishing the value. Idempotent: an already-hashed line passes through untouched, so the same filter can run over both the stored baseline and live dmidecode output.
hash_serials() {
    python3 -c '
import sys, hashlib, re
for line in sys.stdin:
    m = re.match(r"^(\s*Serial Number:\s*)(\S.*?)\s*$", line)
    v = m.group(2) if m else None
    if v and not v.startswith("sha256:") and v not in ("Not Specified", "Unknown"):
        line = m.group(1) + "sha256:" + hashlib.sha256(v.encode()).hexdigest()[:16] + "\n"
    sys.stdout.write(line)
'
}

# Handle IDs are assigned by firmware and can shift between boots without
# anything being wrong, so they are stripped before comparing.
normalise() {
    grep -v '^Handle 0x' | grep -v '^# dmidecode' | grep -v '^SMBIOS' | hash_serials
}

if [[ "${1:-}" == "--update" ]]; then
    mkdir -p "$(dirname "$BASELINE")"
    current | hash_serials > "$BASELINE"
    echo "baseline updated: $BASELINE"
    exit 0
fi

[[ -s "$BASELINE" ]] || {
    echo "no baseline at $BASELINE -- run: $0 --update" >&2
    exit 2
}

if diff -u <(normalise < "$BASELINE") <(current | normalise) > /tmp/spd-check.$$ 2>&1; then
    printf '\033[1;32mOK\033[0m  DIMM identity matches baseline\n'
    grep -E 'Part Number|Serial Number|Configured Memory Speed' "$BASELINE" \
        | sed 's/^\t/  /'
    rm -f /tmp/spd-check.$$
    exit 0
fi

printf '\033[1;31mCHANGED\033[0m  DIMM identity differs from baseline:\n\n'
cat /tmp/spd-check.$$
rm -f /tmp/spd-check.$$
echo
echo "If you did not change the RAM, treat this as possible SPD corruption."
echo "Do not reboot into anything that writes SMBus until you have investigated."
exit 1
