#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Check a vendor_kernel_boot.img before it goes in the zip.
#
# This partition is not chained. The main vbmeta covers it with a hash
# descriptor carrying an explicit Image Size, so libavb reads that many bytes
# from the start and ignores whatever follows. Google's own image is padded to
# the full partition and carries an unsigned footer of its own; ours is the bare
# natural-size artifact and boots identically, because that footer is
# informational rather than a trust anchor. So a footer on ours means something
# signed or padded it by mistake, and the zip has no reason to carry 60 MB of
# padding either.
#
# Nothing here is signed in a way worth checking, so the only integrity test
# available is whether the vendor_boot header's own section sizes add back up to
# the file.
#
# Usage: verify-vkb.sh <vendor_kernel_boot.img>

set -u
IMG=${1:?usage: verify-vkb.sh <vendor_kernel_boot.img>}
HERE=$(cd "$(dirname "$0")/.." && pwd)
AVBTOOL=${AVBTOOL:-$HERE/tools/avbtool}
PART_SIZE=67108864

rc=0
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 2; }
echo "$IMG"

if python3 "$AVBTOOL" info_image --image "$IMG" >/dev/null 2>&1; then
	printf '  FAIL  carries an AVB footer; our build ships this bare\n'
	rc=1
else
	printf '  ok    no AVB footer\n'
fi

python3 - "$IMG" "$PART_SIZE" <<'PY' || rc=1
import os, struct, sys

img, part = sys.argv[1], int(sys.argv[2])
rc = 0
def ok(m):  print(f"  ok    {m}")
def bad(m):
	global rc; rc = 1; print(f"  FAIL  {m}")

d = open(img, 'rb').read(0x900)
if d[:8] != b'VNDRBOOT':
	bad(f"magic: {d[:8]!r} (want b'VNDRBOOT')")
	sys.exit(1)
ok("magic: VNDRBOOT")

hv, page = struct.unpack('<2I', d[8:16])
vrs, = struct.unpack('<I', d[0x18:0x1c])
hs, dtb = struct.unpack('<2I', d[0x830:0x838])
tbl, _, _, cfg = struct.unpack('<4I', d[0x840:0x850])

if hv == 4:
	ok("header version: 4")
else:
	bad(f"header version: {hv} (want 4)")

up = lambda n: (n + page - 1) // page * page
calc = up(hs) + up(vrs) + up(dtb) + up(tbl) + up(cfg)
actual = os.path.getsize(img)
if actual == calc:
	ok(f"size: {actual} matches header sections")
elif actual < calc:
	bad(f"size: {actual}, header describes {calc}; truncated")
else:
	bad(f"size: {actual}, header describes {calc}; trailing data, likely a partition dump")

if actual <= part:
	ok(f"fits the {part}-byte partition")
else:
	bad(f"size: {actual} exceeds the {part}-byte partition")

sys.exit(rc)
PY

if [ $rc -eq 0 ]; then echo "pass"; else echo "fail"; fi
exit $rc
