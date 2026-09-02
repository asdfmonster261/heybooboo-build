#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Sign the built boot.img and package the flashable zip, both out of one dist
# directory. The signed image is kept beside the zip rather than discarded, since
# it is what you RAM-boot with fastboot before writing anything to the device.
#
# Usage: release.sh <dist-dir> <kernel-tree> <output.zip>

set -eu
DIST=${1:?usage: release.sh <dist-dir> <kernel-tree> <output.zip>}
TREE=${2:?}
OUT=${3:?}
HERE=$(cd "$(dirname "$0")/.." && pwd)

BOOT=${OUT%.zip}-boot.img
"$HERE/scripts/sign-boot.sh" "$DIST" "$TREE" "$BOOT"
"$HERE/scripts/make-zip.sh" "$DIST" "$BOOT" "$OUT"
