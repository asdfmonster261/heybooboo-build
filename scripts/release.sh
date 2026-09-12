#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Gate and package the repack zip from the build's boot.img: confirm the repack
# preserves the AVB footer on a stock boot, then build the zip. Nothing is signed;
# the zip repacks on-device and inherits the user's own footer. The dd/pre-signed
# release is release-dd.sh.
#
# Usage: release.sh <boot.img> <output.zip> [stock-boot.img]
#
# Produces two artifacts. The zip repacks on device and so works on ANY patch level,
# because it ships a bare Image and takes the footer from the user's own boot. The
# boot.img is for someone with no root and no custom recovery yet, who cannot run the
# zip at all, and it is PINNED to one patch level: its footer comes from the stock boot
# that gated it. So the patch level goes in that file's name and in the release notes.
#
# Without a stock boot it fetches the newest from Google's OTA, which keeps the gate on
# the current patch level instead of one committed once and left to go stale.

set -eu
BOOT=${1:?usage: release.sh <boot.img> <out.zip> [stock-boot.img]}
OUT=${2:?}
STOCK=${3:-}
HERE=$(cd "$(dirname "$0")/.." && pwd)

# Fetch the v31.0 apk once and share it, so the gate and the packager do not each
# download it.
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
curl -sfL https://github.com/topjohnwu/Magisk/releases/download/v31.0/Magisk-v31.0.apk -o "$work/magisk.apk"
export MAGISK_APK="$work/magisk.apk"

if [ -z "$STOCK" ]; then
  STOCK="$work/stock-boot.img"
  "$HERE/scripts/fetch-stock-boot.sh" "$STOCK" boot
fi

spl_of() {
  python3 "$HERE/tools/avbtool" info_image --image "$1" 2>/dev/null \
    | sed -n "s/.*security_patch -> '\([0-9-]*\)'.*/\1/p" | head -1
}
SPL=$(spl_of "$STOCK")
[ -n "$SPL" ] || { echo "no security_patch in $STOCK; refusing to name an image after it" >&2; exit 1; }
IMG="${OUT%.zip}-spl${SPL}.img"

# The gate keeps its own repacked image, so the published boot.img is the one the
# assertions ran against. Never publish the raw kleaf boot.img: it carries a
# placeholder security_patch of 2027-00-05 and no signature at all, and flashing it
# would bind KeyMint to a patch level no real image can satisfy.
"$HERE/scripts/verify-repack.sh" "$BOOT" "$STOCK" "$IMG"
"$HERE/scripts/make-zip.sh" "$BOOT" "$OUT"

# belt and braces on the above: assert what is about to be published is signed and
# carries the patch level it is named for.
got=$(spl_of "$IMG")
[ "$got" = "$SPL" ] || { echo "published image says patch level '$got', expected '$SPL'" >&2; exit 1; }
python3 "$HERE/tools/avbtool" info_image --image "$IMG" 2>/dev/null | grep -q "Algorithm:  *NONE" \
  && { echo "published image is unsigned; that is the raw build output, not a repack" >&2; exit 1; }

echo "release: $OUT"
echo "         $IMG"
echo "  patch level: $SPL   (zip works on any patch level; the img is pinned to this one)"
