#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the flashable AnyKernel3 zip for the repack model. It ships the kernel
# Image (pulled out of the build's boot.img) plus arm64 v31.0 magiskboot and
# busybox; on device, anykernel.sh repacks the Image into the user's own boot and
# keeps that boot's AVB footer. No signing, no vendor_kernel_boot - anykernel.sh
# explains why. The dd/pre-signed path is make-zip-dd.sh + anykernel-dd.sh.
#
# Usage: make-zip.sh <boot.img> <output.zip>
#   <boot.img>  the build's boot.img; only its kernel is used, the footer is dropped

set -eu
BOOT=${1:?usage: make-zip.sh <boot.img> <out.zip>}
OUT=${2:?}
HERE=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$BOOT" ] || { echo "no such boot.img: $BOOT" >&2; exit 1; }
BOOT=$(readlink -f "$BOOT")
OUT=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")

AK3_URL=https://github.com/osm0sis/AnyKernel3/archive/refs/heads/master.tar.gz
# v31.0 is required: it is the magiskboot that syncs the AVB hash descriptor image
# size on repack (v30.7 left it stale). The apk carries arm64 (for the zip) and
# x86_64 (to unpack boot.img here).
MAGISK_URL=https://github.com/topjohnwu/Magisk/releases/download/v31.0/Magisk-v31.0.apk

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
stage="$work/ak3"; mkdir -p "$stage"

# AK3 upstream, trimmed to what a repack-only zip uses.
curl -sfL "$AK3_URL" | tar -xz -C "$stage" --strip-components=1
rm -rf "$stage/.github" "$stage/README.md" "$stage/modules" "$stage/patch" "$stage/ramdisk"

# From the Magisk apk: arm64 busybox + magiskboot for the zip, x86_64 magiskboot to
# unpack boot.img here. AK3's own tools are 32-bit and dead on this arm64 device;
# anykernel.sh only ever runs busybox and magiskboot, so those are the two to replace.
apk=${MAGISK_APK:-$work/magisk.apk}
[ -f "$apk" ] || curl -sfL "$MAGISK_URL" -o "$apk"
unzip -o -q "$apk" \
	'lib/arm64-v8a/libbusybox.so' \
	'lib/arm64-v8a/libmagiskboot.so' \
	'lib/x86_64/libmagiskboot.so' -d "$work/mg"
mv "$work/mg/lib/arm64-v8a/libbusybox.so"    "$stage/tools/busybox"
mv "$work/mg/lib/arm64-v8a/libmagiskboot.so" "$stage/tools/magiskboot"
mbhost="$work/mg/lib/x86_64/libmagiskboot.so"
chmod 755 "$stage/tools/busybox" "$stage/tools/magiskboot" "$mbhost"

for pair in "busybox|$stage/tools/busybox" "magiskboot|$stage/tools/magiskboot"; do
	n=${pair%%|*}; f=${pair#*|}
	case "$(file -b "$f")" in
		*"ELF 64-bit"*aarch64*) ;;
		*) echo "$n is not arm64 - the zip would fail on device" >&2; exit 1 ;;
	esac
done

# Pull the raw kernel Image out of the build's boot.img. magiskboot decompresses it;
# the on-device repack recompresses it to match the user's boot. boot.img unpacks
# with rc 0, so a missing kernel file is the real failure signal.
( cd "$work" && "$mbhost" unpack "$BOOT" >/dev/null 2>&1 ) || true
[ -f "$work/kernel" ] || { echo "no kernel extracted from $BOOT" >&2; exit 1; }
case "$(file -b "$work/kernel")" in
	*"ARM64 boot executable Image"*) ;;
	*) echo "extracted kernel from $BOOT is not an arm64 Image" >&2; exit 1 ;;
esac
cp "$work/kernel" "$stage/Image"

# Our repack flasher, with the shipped Image's checksum stamped in so a truncated
# download aborts instead of repacking a partial kernel.
cp "$HERE/anykernel/anykernel.sh" "$stage/anykernel.sh"
isha=$(sha256sum "$stage/Image" | cut -d' ' -f1)
sed -i "s/^IMAGESHA=.*/IMAGESHA=$isha;/" "$stage/anykernel.sh"
grep -q "^IMAGESHA=$isha;" "$stage/anykernel.sh" || { echo "failed to stamp Image checksum" >&2; exit 1; }

python3 - "$stage" "$OUT" <<'PY'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
files=[]
for dp,_,fns in os.walk(root):
    for fn in fns:
        files.append(os.path.relpath(os.path.join(dp,fn), root))
with zipfile.ZipFile(out,"w",zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for rel in sorted(files):
        full=os.path.join(root,rel)
        zi=zipfile.ZipInfo(rel, date_time=(2026,1,1,0,0,0))
        zi.external_attr=(os.stat(full).st_mode & 0xFFFF) << 16
        zi.compress_type=zipfile.ZIP_DEFLATED
        with open(full,'rb') as f: z.writestr(zi, f.read())
print(f"wrote {out} ({os.path.getsize(out):,} bytes)")
PY
