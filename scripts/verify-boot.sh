#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Check a signed boot.img before it goes near the device.
#
# Do not reduce this to a verify_image call. avbtool returns 0 on a completely
# unsigned image, because all it asks is whether the vbmeta struct is
# self-consistent, and "Algorithm: NONE" is self-consistent. The footer
# properties are what KeyMint reads for the boot patch level, and they have to
# be asserted by hand. Kleaf's own boot.img passes verify_image and would break
# /data.
#
# The expected values below are a second copy of the ones in sign-boot.sh. That
# is the point: a verifier that reads its expectations from the artifact
# confirms nothing.
#
# Usage: verify-boot.sh <boot.img> [kernel-tree]
#   kernel-tree is optional and only adds an explicit key check.

set -u
IMG=${1:?usage: verify-boot.sh <boot.img> [kernel-tree]}
TREE=${2:-}
HERE=$(cd "$(dirname "$0")/.." && pwd)
AVBTOOL=${AVBTOOL:-$HERE/tools/avbtool}

PART_SIZE=67108864
SPL=2026-08-05
OS_VERSION=17
FINGERPRINT='google/yogi/yogi:17/CD1A.260714.001.A9/15938155:user/release-keys'
PUBKEY_SHA1=2597c218aae470a130f61162feaae70afd97f011
ALGORITHM=SHA256_RSA4096

rc=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; rc=1; }
want() {
	if [ "$2" = "$3" ]; then ok "$1: $2"; else bad "$1: $2 (want $3)"; fi
}

[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 2; }

INFO=$(python3 "$AVBTOOL" info_image --image "$IMG" 2>&1) || {
	printf '%s\n' "$IMG" "$INFO" >&2
	exit 1
}

# info_image writes the footer size as "Image size" and the hash descriptor's as
# "Image Size". Case is the only thing separating them, so match case-sensitively.
field() {
	printf '%s\n' "$INFO" | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -1 | sed 's/ bytes$//'
}
prop() {
	printf '%s\n' "$INFO" | sed -n "s/^[[:space:]]*Prop: $1 -> '\(.*\)'\$/\1/p" | head -1
}

echo "$IMG"
want "file size"       "$(stat -c%s "$IMG")"                          "$PART_SIZE"
want "image size"      "$(field 'Image size')"                        "$PART_SIZE"
want "partition"       "$(field 'Partition Name')"                    boot
want "algorithm"       "$(field 'Algorithm')"                         "$ALGORITHM"
want "public key"      "$(field 'Public key (sha1)')"                 "$PUBKEY_SHA1"
want "rollback index"  "$(field 'Rollback Index')"                    "$(date -u -d "$SPL" +%s)"
want "os_version"      "$(prop com.android.build.boot.os_version)"     "$OS_VERSION"
want "security_patch"  "$(prop com.android.build.boot.security_patch)" "$SPL"
want "fingerprint"     "$(prop com.android.build.boot.fingerprint)"    "$FINGERPRINT"

payload=$(field 'Original image size')
if [ "${payload:-0}" -gt 0 ] && [ "$payload" -lt "$PART_SIZE" ]; then
	ok "payload: $payload bytes"
else
	bad "payload: ${payload:-none} does not fit $PART_SIZE"
fi

keyarg=()
if [ -n "$TREE" ]; then
	key=$TREE/tools/mkbootimg/gki/testdata/testkey_rsa4096.pem
	if [ -f "$key" ]; then keyarg=(--key "$key"); else bad "no signing key at $key"; fi
fi
# verify_image resolves the hash descriptor's partition name to <name>.img in
# the image's own directory and hashes that, not the file it was handed. Hand it
# an empty directory or a renamed image gets checked against its neighbour.
vdir=$(mktemp -d); trap 'rm -rf "$vdir"' EXIT
ln -s "$(readlink -f "$IMG")" "$vdir/boot.img"
if python3 "$AVBTOOL" verify_image --image "$vdir/boot.img" ${keyarg+"${keyarg[@]}"} >/dev/null 2>&1; then
	ok "hash and signature verify"
else
	bad "avbtool verify_image rejected the image"
fi

if [ $rc -eq 0 ]; then echo "pass"; else echo "fail"; fi
exit $rc
