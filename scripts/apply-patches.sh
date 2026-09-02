#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Apply the vendor module patches to an extracted GPL drop. The kernel comes
# from heybooboo-kernel; these fix modules under private/, which Google ships
# only in the tarball.
#
# Usage: apply-patches.sh <path-to-extracted-kernel-tarball>

set -eu
TREE=${1:?usage: apply-patches.sh <kernel tree>}
HERE=$(cd "$(dirname "$0")/.." && pwd)

[ -d "$TREE/private/google-modules" ] || { echo "not a kernel drop: $TREE" >&2; exit 1; }

for p in "$HERE"/patches/*.patch; do
	name=$(basename "$p")
	if patch -d "$TREE" -p1 --dry-run --silent < "$p" >/dev/null 2>&1; then
		patch -d "$TREE" -p1 --silent < "$p"
		echo "applied  $name"
	elif patch -d "$TREE" -p1 -R --dry-run --silent < "$p" >/dev/null 2>&1; then
		echo "already  $name"
	else
		echo "FAILED   $name" >&2
		exit 1
	fi
done
