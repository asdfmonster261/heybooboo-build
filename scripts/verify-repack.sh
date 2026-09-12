#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Host-side release gate for the repack zip. Repacks the kernel into a stock boot
# with the same v31.0 magiskboot the zip ships, and asserts the AVB footer came
# through intact: the KeyMint-read props are byte-identical to the stock boot (so
# the patch level survives and /data still decrypts), the hash descriptor image
# size tracks the new kernel, and the kernel in the result is the shipped one.
#
# It does NOT check a signature. magiskboot does not re-sign and need not: the
# bootloader is unlocked, so only the props are read. That is also why this is a
# preservation check against the stock boot rather than a check against pinned
# values - the point of the model is that the level comes from the user's boot.
# (verify-boot.sh, the pinned/crypto checker, is for the dd/pre-signed path.)
#
# Usage: verify-repack.sh <boot.img> <stock-boot.img>
#   The stock boot is required on purpose. It used to default to the project's
#   yogi_boot_img/boot.img, which goes stale the moment an OTA lands: the gate would
#   then assert preservation against last release's patch level and still say pass.
#   release.sh fetches a current one with fetch-stock-boot.sh.

set -u
OURS=${1:?usage: verify-repack.sh <boot.img> <stock-boot.img>}
HERE=$(cd "$(dirname "$0")/.." && pwd)
STOCK=${2:?usage: verify-repack.sh <boot.img> <stock-boot.img>}
AVBTOOL=${AVBTOOL:-$HERE/tools/avbtool}
MAGISK_URL=https://github.com/topjohnwu/Magisk/releases/download/v31.0/Magisk-v31.0.apk

[ -f "$OURS" ]  || { echo "no such boot.img: $OURS" >&2; exit 2; }
[ -f "$STOCK" ] || { echo "no stock boot.img: $STOCK" >&2; exit 2; }
OURS=$(readlink -f "$OURS"); STOCK=$(readlink -f "$STOCK")

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

apk=${MAGISK_APK:-$work/magisk.apk}
[ -f "$apk" ] || curl -sfL "$MAGISK_URL" -o "$apk"
unzip -o -q "$apk" 'lib/x86_64/libmagiskboot.so' -d "$work/mg"
MB="$work/mg/lib/x86_64/libmagiskboot.so"
[ -f "$MB" ] || { echo "no host magiskboot from apk" >&2; exit 1; }
chmod 755 "$MB"

# the kernel out of the built boot
( cd "$work" && "$MB" unpack "$OURS" >/dev/null 2>&1 ) || true
[ -f "$work/kernel" ] || { echo "no kernel in $OURS" >&2; exit 1; }
oursha=$(sha256sum "$work/kernel" | cut -d' ' -f1)

# repack the kernel into a copy of stock
rp="$work/rp"; mkdir -p "$rp"; cp "$STOCK" "$rp/stock.img"; cp "$work/kernel" "$rp/our-kernel"
( cd "$rp" && "$MB" unpack stock.img >/dev/null 2>&1 && cp our-kernel kernel && "$MB" repack stock.img new.img >/dev/null 2>&1 ) || true
[ -f "$rp/new.img" ] || { echo "repack failed" >&2; exit 1; }

rc=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; rc=1; }
want() { if [ "$2" = "$3" ]; then ok "$1: $2"; else bad "$1: $2 (want $3)"; fi; }

infoS=$(python3 "$AVBTOOL" info_image --image "$STOCK" 2>&1)
infoN=$(python3 "$AVBTOOL" info_image --image "$rp/new.img" 2>&1)
# "Image size" is the footer/partition size; "Image Size" is the hash descriptor.
# Case is the only thing between them, so match case-sensitively.
field() { printf '%s\n' "$2" | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -1 | sed 's/ bytes$//'; }
prop()  { printf '%s\n' "$2" | sed -n "s/^[[:space:]]*Prop: $1 -> '\(.*\)'\$/\1/p" | head -1; }

echo "repack of $OURS into $STOCK"

n=$(wc -c < "$rp/new.img")
if [ "$(dd if="$rp/new.img" bs=1 skip=$((n-64)) count=4 2>/dev/null)" = "AVBf" ]; then ok "AVB footer present"; else bad "no AVB footer"; fi

for p in os_version security_patch fingerprint; do
	want "$p preserved" "$(prop "com.android.build.boot.$p" "$infoN")" "$(prop "com.android.build.boot.$p" "$infoS")"
done

want "descriptor size == payload" "$(field 'Image Size' "$infoN")" "$(field 'Original image size' "$infoN")"
want "padded to partition"        "$(field 'Image size' "$infoN")" "$(field 'Image size' "$infoS")"

rt="$work/rt"; mkdir -p "$rt"; ( cd "$rt" && "$MB" unpack "$rp/new.img" >/dev/null 2>&1 ) || true
want "our kernel landed" "$(sha256sum "$rt/kernel" 2>/dev/null | cut -d' ' -f1)" "$oursha"

if [ $rc -eq 0 ]; then echo "pass"; else echo "fail"; fi
exit $rc
