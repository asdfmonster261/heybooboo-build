#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the flashable AnyKernel3 zip. Both images must come from the same build:
# modules in the vendor_kernel_boot ramdisk carry symbol CRCs tied to that kernel.
#
# Usage: make-zip.sh <signed-boot.img> <vendor_kernel_boot.img> <output.zip>

set -eu
BOOT=${1:?usage: make-zip.sh <boot.img> <vendor_kernel_boot.img> <out.zip>}
VKB=${2:?}
OUT=${3:?}
HERE=$(cd "$(dirname "$0")/.." && pwd)
AK3_URL=https://github.com/osm0sis/AnyKernel3/archive/refs/heads/master.tar.gz
MAGISK_URL=https://github.com/topjohnwu/Magisk/releases/download/v30.7/app-debug.apk

# The footer and the AK3 guard carry the patch level separately, and after an OTA
# they are the pair that drifts. anykernel.sh says why the guard is pinned in
# both directions rather than left open at the bottom.
spl=$(python3 "$HERE/tools/avbtool" info_image --image "$BOOT" 2>/dev/null |
	sed -n "s/.*com\.android\.build\.boot\.security_patch -> '\(....-..\).*/\1/p")
[ -n "$spl" ] || { echo "no security_patch prop in $BOOT" >&2; exit 1; }
lvl=$(sed -n 's/^supported\.patchlevels=\(.*\)$/\1/p' "$HERE/anykernel/anykernel.sh")
[ "$lvl" = "$spl - $spl" ] || {
	echo "anykernel.sh allows '$lvl' but boot.img is signed $spl" >&2
	exit 1
}

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
curl -sfL "$AK3_URL" | tar -xz -C "$work" --strip-components=1
rm -rf "$work/.github" "$work/README.md" "$work/modules" "$work/patch" "$work/ramdisk"

# AK3 ships every tool as 32-bit ARM and yogi is arm64 only, so they cannot
# execute. anykernel.sh only ever calls busybox, so that is the only one worth
# replacing. Taken from a pinned Magisk release rather than /data/adb/magisk so
# the build does not need a device attached.
curl -sfL "$MAGISK_URL" -o "$work/magisk.apk"
unzip -o -q "$work/magisk.apk" 'lib/arm64-v8a/libbusybox.so' -d "$work/mg"
mv "$work/mg/lib/arm64-v8a/libbusybox.so" "$work/tools/busybox"
rm -rf "$work/magisk.apk" "$work/mg"
chmod 755 "$work/tools/busybox"
case "$(file -b "$work/tools/busybox")" in
	*"ELF 64-bit"*aarch64*) ;;
	*) echo "busybox is not arm64 - the zip would fail on device" >&2; exit 1 ;;
esac

cp "$HERE/anykernel/anykernel.sh" "$work/anykernel.sh"
cp "$BOOT" "$work/boot.img"
cp "$VKB"  "$work/vendor_kernel_boot.img"

# anykernel.sh verifies both images before writing anything; stamp in the real
# checksums so a truncated download aborts instead of flashing a partial image.
bsha=$(sha256sum "$work/boot.img" | cut -d' ' -f1)
vsha=$(sha256sum "$work/vendor_kernel_boot.img" | cut -d' ' -f1)
sed -i "s/^BOOTSHA=.*/BOOTSHA=$bsha;/; s/^VKBSHA=.*/VKBSHA=$vsha;/" "$work/anykernel.sh"

python3 - "$work" "$OUT" <<'PY'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
files=[]
for dp,_,fns in os.walk(root):
    for fn in fns:
        full=os.path.join(dp,fn)
        files.append(os.path.relpath(full, root))
with zipfile.ZipFile(out,"w",zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for rel in sorted(files):
        full=os.path.join(root,rel)
        zi=zipfile.ZipInfo(rel, date_time=(2026,1,1,0,0,0))
        zi.external_attr=(os.stat(full).st_mode & 0xFFFF) << 16
        zi.compress_type=zipfile.ZIP_DEFLATED
        with open(full,'rb') as f: z.writestr(zi, f.read())
print(f"wrote {out} ({os.path.getsize(out):,} bytes)")
PY
