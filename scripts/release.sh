#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Gate and package the repack zip from the build's boot.img: confirm the repack
# preserves the AVB footer on a stock boot, then build the zip. Nothing is signed;
# the zip repacks on-device and inherits the user's own footer. The dd/pre-signed
# release is release-dd.sh.
#
# Usage: release.sh <boot.img> <output.zip> [stock-boot.img]

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

"$HERE/scripts/verify-repack.sh" "$BOOT" ${STOCK:+"$STOCK"}
"$HERE/scripts/make-zip.sh" "$BOOT" "$OUT"

echo "release: $OUT"
