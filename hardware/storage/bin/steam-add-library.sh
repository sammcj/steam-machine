#!/usr/bin/env bash
# Register the BTRFS mirror as a Steam library folder, so it shows up in
# Settings -> Storage as a second drive and games can be installed to it.
#
# This is a ONE-TIME step and it must run with STEAM CLOSED. Steam holds
# libraryfolders.vdf in memory and rewrites it on exit, so edits made while it
# is running are silently discarded.
#
# The safe alternative, if you would rather Steam do it itself: switch to
# desktop mode, then Steam -> Settings -> Storage -> the "+" button -> pick
# /home/deck/SATA. Identical result. Use this script when you want it done
# without a desktop session.
#
#   ./steam-add-library.sh            add the library
#   ./steam-add-library.sh --check    report status, change nothing
set -euo pipefail

MOUNT_POINT="${GAMES_MOUNT:-/home/deck/SATA}"
VDF="/home/deck/.steam/steam/steamapps/libraryfolders.vdf"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

registered() { grep -qF "\"$MOUNT_POINT\"" "$VDF" 2>/dev/null; }

if [[ "${1:-}" == "--check" ]]; then
    echo -n "mounted:     "; grep -q " $MOUNT_POINT btrfs " /proc/mounts && echo yes || echo NO
    echo -n "steam:       "; pgrep -x steam >/dev/null && echo "RUNNING (close it first)" || echo "not running"
    echo -n "registered:  "; registered && echo yes || echo no
    exit 0
fi

[[ $EUID -eq 0 ]] && die "run this as deck, not root -- it writes into the user's Steam config"

grep -q " $MOUNT_POINT btrfs " /proc/mounts \
    || die "$MOUNT_POINT is not mounted; run ../install.sh first"

if pgrep -x steam >/dev/null; then
    die "Steam is running. Close it completely and re-run, or add the folder from
       Steam -> Settings -> Storage -> '+' -> $MOUNT_POINT"
fi

[[ -f "$VDF" ]] || die "no $VDF -- has Steam ever been run?"

if registered; then
    log "$MOUNT_POINT is already registered as a Steam library"
    exit 0
fi

# Steam matches the entry in libraryfolders.vdf against a marker file inside the
# library itself; the contentid must be the same in both or Steam treats the
# folder as unrecognised and re-adds it.
CONTENTID="$(od -An -N8 -tu8 /dev/urandom | tr -d ' \n')"

log "creating library structure under $MOUNT_POINT"
mkdir -p "$MOUNT_POINT/steamapps/common"
cat > "$MOUNT_POINT/steamapps/libraryfolder.vdf" <<EOF
"libraryfolder"
{
	"contentid"		"$CONTENTID"
	"label"		""
}
EOF

log "backing up $VDF -> $VDF.bak"
cp -a "$VDF" "$VDF.bak"

python3 - "$VDF" "$MOUNT_POINT" "$CONTENTID" <<'PY'
import re, sys

vdf_path, mount, contentid = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(vdf_path, encoding="utf-8").read()

# Entries are keyed by consecutive integers; take the next free one rather than
# assuming "1" -- there may already be an SD card or a second library.
used = [int(m) for m in re.findall(r'^\t"(\d+)"\s*$', text, re.M)]
idx = max(used) + 1 if used else 0

entry = (
    f'\t"{idx}"\n'
    '\t{\n'
    f'\t\t"path"\t\t"{mount}"\n'
    '\t\t"label"\t\t""\n'
    f'\t\t"contentid"\t\t"{contentid}"\n'
    '\t\t"totalsize"\t\t"0"\n'
    '\t\t"update_clean_bytes_tally"\t\t"0"\n'
    '\t\t"time_last_update_verified"\t\t"0"\n'
    '\t\t"apps"\n'
    '\t\t{\n'
    '\t\t}\n'
    '\t}\n'
)

# Insert before the final closing brace of the top-level block.
close = text.rstrip().rfind('}')
if close == -1:
    sys.exit("libraryfolders.vdf has no closing brace -- refusing to edit")
out = text[:close] + entry + text[close:]

# Cheap structural check: braces must still balance, and we must have added
# exactly one entry.
if out.count('{') != text.count('{') + 2 or out.count('}') != text.count('}') + 2:
    sys.exit("edit did not balance -- refusing to write")

open(vdf_path, "w", encoding="utf-8").write(out)
print(f"added library index {idx} -> {mount}")
PY

log "done. Start Steam and check Settings -> Storage."
log "If anything looks wrong, restore with: cp $VDF.bak $VDF"
