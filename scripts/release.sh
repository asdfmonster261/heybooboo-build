#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Gate and package the repack zip from the build's boot.img: confirm the repack
# preserves the AVB footer on a stock boot, then build the zip. Nothing is signed;
# the zip repacks on-device and inherits the user's own footer. The dd/pre-signed
# release is release-dd.sh.
#
# Usage: release.sh <boot.img> <output.zip> [stock-boot.img]
#   Without a stock boot it fetches the newest one from Google's OTA, so the gate
#   always runs against the current patch level. The patch level is then read back out
#   of that image and printed, because it belongs in the release notes: the zip works
#   on any patch level, but a published boot.img is pinned to this one.

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

"$HERE/scripts/verify-repack.sh" "$BOOT" "$STOCK"
"$HERE/scripts/make-zip.sh" "$BOOT" "$OUT"

SPL=$(python3 "$HERE/tools/avbtool" info_image --image "$STOCK" 2>/dev/null \
  | sed -n "s/.*security_patch -> '\([0-9-]*\)'.*/\1/p" | head -1)
echo "release: $OUT"
echo "  gated against stock patch level: ${SPL:-unknown}"
