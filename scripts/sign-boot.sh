#!/bin/bash
# Re-sign a built boot.img. Kleaf's own footer is unsigned, sized wrong, and
# claims security_patch 2027-00-05 - not a date. Flashing that risks KeyMint
# recording a bogus level and refusing /data afterwards.
#
# Usage: sign-boot.sh <dist-dir> <kernel-tree> <output.img>

set -eu
DIST=${1:?usage: sign-boot.sh <dist> <kernel tree> <out>}
TREE=${2:?}
OUT=${3:?}
HERE=$(cd "$(dirname "$0")/.." && pwd)

AVBTOOL=${AVBTOOL:-$HERE/tools/avbtool}
KEY=$TREE/tools/mkbootimg/gki/testdata/testkey_rsa4096.pem
PART_SIZE=67108864
SPL=2026-08-05
FINGERPRINT='google/yogi/yogi:17/CD1A.260714.001.A9/15938155:user/release-keys'

[ -x "$AVBTOOL" ] || [ -f "$AVBTOOL" ] || { echo "no avbtool at $AVBTOOL" >&2; exit 1; }
[ -f "$KEY" ] || { echo "no signing key at $KEY" >&2; exit 1; }

cp "$DIST/boot.img" "$OUT"
python3 "$AVBTOOL" erase_footer --image "$OUT"
python3 "$AVBTOOL" add_hash_footer \
	--image "$OUT" \
	--partition_name boot \
	--partition_size "$PART_SIZE" \
	--algorithm SHA256_RSA4096 \
	--key "$KEY" \
	--rollback_index $(( $(date -u -d "$SPL" +%s) )) \
	--prop com.android.build.boot.os_version:17 \
	--prop "com.android.build.boot.security_patch:$SPL" \
	--prop "com.android.build.boot.fingerprint:$FINGERPRINT"

echo "signed $OUT ($(stat -c%s "$OUT") bytes)"
python3 "$AVBTOOL" info_image --image "$OUT" | sed -n '1,8p'
