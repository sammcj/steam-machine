#!/usr/bin/env python3
"""Patch the LG C9's EDID to allow 4K120 over HDMI 2.0 using 4:2:0 chroma.

This is the *fallback* path, kept for reference. The supported fix is the active
DP-to-HDMI 2.1 converter -- see README.md. Read the trade-offs there before
using this: the result is 4:2:0 8-bit only, so text is soft and HDR bands.

The C9 advertises 4K120 (VIC 118) in its plain Video Data Block, which needs
1188 MHz and therefore HDMI 2.1 FRL. Its YCbCr 4:2:0 Capability Map -- the block
that says "these modes may also be sent as 4:2:0" -- lists only 4K60/50. So
amdgpu has no legal way to fit 4K120 into HDMI 2.0's 600 MHz TMDS budget, and
prunes the mode.

Setting the capability-map bits for VIC 118 and VIC 117 halves their bandwidth
to 594/495 MHz, which fits. amdgpu additionally requires force_yuv420_output=1
for modes that are "420-also" rather than "420-only".

Usage:
    ./generate-420-edid.py [-o out.bin]
    sudo tee /sys/kernel/debug/dri/0/HDMI-A-1/edid_override < out.bin
    echo 1 | sudo tee /sys/kernel/debug/dri/0/HDMI-A-1/force_yuv420_output
    echo 1 | sudo tee /sys/kernel/debug/dri/0/HDMI-A-1/trigger_hotplug

Neither debugfs knob persists across reboot.

ARM A REVERT TIMER FIRST. The TV is this machine's only console:
    (sleep 20; kscreen-doctor output.HDMI-A-1.mode.<safe-idx>) &
"""

import argparse
import sys

EDID_PATH = "/sys/class/drm/card0-HDMI-A-1/edid"

EXT = 128           # offset of the CTA-861 extension block
CMDB_BITMAP = 93    # offset within that block of the 4:2:0 capability bitmap
CHECKSUM = 127      # offset within that block of its checksum

# Bit positions index into the Video Data Block's SVD list, which on this panel
# is: [0]=VIC 97 (4K60), [1]=VIC 96 (4K50), [2]=VIC 118 (4K120),
#     [3]=VIC 117 (4K100), [4]=VIC 102, [5]=VIC 101, ...
# Stock value is 0x33 = bits 0,1,4,5. Adding bits 2,3 adds 4K120 and 4K100.
ADD_BITS = 0x0C


def patch(edid: bytes) -> bytes:
    if len(edid) < 256:
        sys.exit(f"expected at least 256 bytes of EDID, got {len(edid)}")

    e = bytearray(edid)
    off = EXT + CMDB_BITMAP

    before = e[off]
    e[off] = before | ADD_BITS
    if e[off] == before:
        print(f"4:2:0 capability map already 0x{before:02x}; nothing to do")
    else:
        print(f"4:2:0 capability map: 0x{before:02x} -> 0x{e[off]:02x}")

    # CTA extension checksum: all 128 bytes of the block must sum to 0 mod 256.
    e[EXT + CHECKSUM] = (-sum(e[EXT:EXT + CHECKSUM])) & 0xFF
    print(f"extension checksum:   0x{edid[EXT + CHECKSUM]:02x} -> 0x{e[EXT + CHECKSUM]:02x}")

    return bytes(e)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-i", "--input", default=EDID_PATH,
                    help=f"source EDID (default: {EDID_PATH})")
    ap.add_argument("-o", "--output", default="c9-4k120-420.bin",
                    help="output file (default: c9-4k120-420.bin)")
    ap.add_argument("--revert", action="store_true",
                    help="produce the stock EDID instead (clears the added bits)")
    args = ap.parse_args()

    # NB: reading the sysfs EDID while an override is already active returns the
    # OVERRIDE, not the panel's real EDID. Use --revert to reconstruct the stock
    # one rather than reading it back in that state.
    with open(args.input, "rb") as f:
        edid = f.read()

    if args.revert:
        e = bytearray(edid)
        e[EXT + CMDB_BITMAP] &= ~ADD_BITS & 0xFF
        e[EXT + CHECKSUM] = (-sum(e[EXT:EXT + CHECKSUM])) & 0xFF
        out = bytes(e)
        print(f"reverted to 0x{out[EXT + CMDB_BITMAP]:02x}, "
              f"checksum 0x{out[EXT + CHECKSUM]:02x}")
    else:
        out = patch(edid)

    with open(args.output, "wb") as f:
        f.write(out)
    print(f"wrote {args.output} ({len(out)} bytes)")
    print(f"verify with: edid-decode {args.output}")


if __name__ == "__main__":
    main()
