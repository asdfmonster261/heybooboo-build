#!/usr/bin/env bash
# Fetch a stock partition image straight out of Google's newest full OTA for a device,
# without downloading the 3-4 GB zip.
#
#   fetch-stock-boot.sh <out.img> [partition] [device]     defaults: boot, yogi
#
# The release gate (verify-repack.sh) asserts that the repack preserves the stock boot's
# KeyMint props, so it needs a stock boot to compare against. Fetching it per run keeps
# the gate on the CURRENT patch level instead of a 64 MB image committed once and then
# quietly going stale.
#
# The newest OTA is picked by sorting the build IDs, since a patch level only ever goes
# up. Nothing here trusts that though: the caller should read the patch level back out of
# the image it got, which is a measured fact rather than an assumption about ordering.
#
# Needs: bash, curl, od, dd, awk, xz, bzip2, sha256sum, truncate. No python, no device.
set -euo pipefail

OUTF=${1:?usage: fetch-stock-boot.sh <out.img> [partition] [device]}
PART=${2:-boot}
DEVICE=${3:-yogi}

OTA_PAGE='https://developers.google.com/android/ota'
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'
# The OTA links are behind a terms-of-service wall; without the ack cookie the page comes
# back with the download URLs stripped out rather than with an error.
COOKIE='devsite_wall_acks=nexus-ota-tos'

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
d="$W/f"; mkdir -p "$d"

cfetch(){ curl -fsSL --retry 3 -A "$UA" -b "$COOKIE" "$@"; }
rget(){ local s=$1 l=$2 o=$3; cfetch -r "$s-$(( s + l - 1 ))" "$URL" -o "$o"; }
le_int(){ local v=0 sh=0 b; for b in $(dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | od -An -tu1 -v); do v=$(( v | (b << sh) )); sh=$(( sh + 8 )); done; echo "$v"; }
be_int(){ local v=0 b;   for b in $(dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | od -An -tu1 -v); do v=$(( (v << 8) | b )); done; echo "$v"; }
vfile(){ local f=$1 off=$2 sh=0 v=0 n=0 b; for b in $(dd if="$f" bs=1 skip="$off" count=10 2>/dev/null | od -An -tu1 -v); do v=$(( v | ((b & 127) << sh) )); n=$(( n + 1 )); if [ "$b" -lt 128 ]; then break; fi; sh=$(( sh + 7 )); done; VV=$v; VN=$(( off + n )); }
vhex(){ local h=$1 i=$2 sh=0 v=0 b; while :; do b=$(( 16#${h:i*2:2} )); v=$(( v | ((b & 127) << sh) )); i=$(( i + 1 )); if [ "$b" -lt 128 ]; then break; fi; sh=$(( sh + 7 )); done; VV=$v; VN=$i; }

# --- newest OTA for the device ---
links=$(cfetch "$OTA_PAGE" \
  | grep -oE "https://dl\.google\.com/dl/android/aosp/${DEVICE}-ota-[a-z0-9.]+-[0-9a-f]+\.zip" \
  | sort -u) || true
[ -n "$links" ] || { echo "no OTA links for '$DEVICE' on the OTA page" >&2; exit 1; }
URL=$(printf '%s\n' "$links" | awk -F'-ota-' '{split($2,a,"-"); print a[1]"\t"$0}' | sort | tail -1 | cut -f2)
BUILD=$(printf '%s' "$URL" | sed -E "s#.*/${DEVICE}-ota-([a-z0-9.]+)-[0-9a-f]+\.zip#\1#" | tr 'a-z' 'A-Z')
echo "  device=$DEVICE  newest build=$BUILD  ($(printf '%s\n' "$links" | wc -l) OTAs listed)"

# --- locate payload.bin inside the zip, by range request ---
TOTAL=$(cfetch -sI "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)
[ -n "$TOTAL" ] || { echo "no content-length for $URL" >&2; exit 1; }
t=65600; [ "$t" -gt "$TOTAL" ] && t=$TOTAL
rget $(( TOTAL - t )) "$t" "$d/tail"
th=$(od -An -tx1 -v "$d/tail" | tr -d ' \n')
ep=$(echo "$th" | grep -bo '504b0506' | tail -1 | cut -d: -f1); [ -n "$ep" ] || { echo "no EOCD" >&2; exit 1; }
eo=$(( ep / 2 )); cds=$(le_int "$d/tail" $(( eo + 12 )) 4); cdo=$(le_int "$d/tail" $(( eo + 16 )) 4)
if [ "$cdo" = 4294967295 ] || [ "$cds" = 4294967295 ]; then echo "ZIP64 OTA not handled" >&2; exit 1; fi
rget "$cdo" "$cds" "$d/cd"
co=0; pay_lho=''
while [ "$co" -lt "$cds" ]; do
  sig=$(le_int "$d/cd" "$co" 4); [ "$sig" = 33639248 ] || break
  method=$(le_int "$d/cd" $(( co + 10 )) 2); fnl=$(le_int "$d/cd" $(( co + 28 )) 2)
  exl=$(le_int "$d/cd" $(( co + 30 )) 2); cml=$(le_int "$d/cd" $(( co + 32 )) 2); lho=$(le_int "$d/cd" $(( co + 42 )) 4)
  name=$(dd if="$d/cd" bs=1 skip=$(( co + 46 )) count="$fnl" 2>/dev/null)
  # payload.bin is STORED, which is what makes range-fetching its ops possible at all.
  if [ "$name" = "payload.bin" ]; then [ "$method" = 0 ] || { echo "payload.bin is compressed" >&2; exit 1; }; pay_lho=$lho; break; fi
  co=$(( co + 46 + fnl + exl + cml ))
done
[ -n "$pay_lho" ] || { echo "payload.bin not found in the central directory" >&2; exit 1; }
rget "$pay_lho" 30 "$d/lh"; lfn=$(le_int "$d/lh" 26 2); lex=$(le_int "$d/lh" 28 2)
PAY=$(( pay_lho + 30 + lfn + lex ))
rget "$PAY" 24 "$d/ph"; [ "$(dd if="$d/ph" bs=1 count=4 2>/dev/null)" = "CrAU" ] || { echo "bad payload magic" >&2; exit 1; }
ver=$(be_int "$d/ph" 4 8); msize=$(be_int "$d/ph" 12 8)
sig2=0; [ "$ver" -ge 2 ] && sig2=$(be_int "$d/ph" 20 4)
rget $(( PAY + 24 )) "$msize" "$d/man"; DATABASE=$(( PAY + 24 + msize + sig2 ))

# --- find the partition in the update_engine manifest (hand-parsed protobuf) ---
BLOCK=4096; pu_off=-1; pu_len=0; mo=0
while [ "$mo" -lt "$msize" ]; do
  vfile "$d/man" "$mo"; tag=$VV; mo=$VN; fn=$(( tag >> 3 )); wt=$(( tag & 7 ))
  case "$wt" in
    0) vfile "$d/man" "$mo"; [ "$fn" = 3 ] && BLOCK=$VV; mo=$VN;;
    1) mo=$(( mo + 8 ));;
    5) mo=$(( mo + 4 ));;
    2) vfile "$d/man" "$mo"; ln=$VV; cs=$VN
       if [ "$fn" = 13 ]; then t0=$(le_int "$d/man" "$cs" 1)
         if [ "$t0" = 10 ]; then nl=$(le_int "$d/man" $(( cs + 1 )) 1); nm=$(dd if="$d/man" bs=1 skip=$(( cs + 2 )) count="$nl" 2>/dev/null)
           if [ "$nm" = "$PART" ]; then pu_off=$cs; pu_len=$ln; break; fi; fi; fi
       mo=$(( cs + ln ));;
  esac
done
[ "$pu_off" -ge 0 ] || { echo "'$PART' is not in the OTA manifest" >&2; exit 1; }
dd if="$d/man" bs=1 skip="$pu_off" count="$pu_len" 2>/dev/null > "$d/pu"
PH=$(od -An -tx1 -v "$d/pu" | tr -d ' \n'); plen=$(( ${#PH} / 2 ))
PSIZE=0; PHASH=''; i=0; OPS=()
while [ "$i" -lt "$plen" ]; do
  vhex "$PH" "$i"; tag=$VV; i=$VN; fn=$(( tag >> 3 )); wt=$(( tag & 7 ))
  if [ "$wt" = 0 ]; then vhex "$PH" "$i"; i=$VN
  elif [ "$wt" = 2 ]; then vhex "$PH" "$i"; ln=$VV; st=$VN
    if [ "$fn" = 7 ]; then j=$st; e=$(( st + ln ))
      while [ "$j" -lt "$e" ]; do vhex "$PH" "$j"; it=$VV; j=$VN; ifn=$(( it >> 3 )); iwt=$(( it & 7 ))
        if [ "$iwt" = 0 ]; then vhex "$PH" "$j"; [ "$ifn" = 1 ] && PSIZE=$VV; j=$VN
        elif [ "$iwt" = 2 ]; then vhex "$PH" "$j"; hl=$VV; hs=$VN; [ "$ifn" = 2 ] && PHASH=${PH:hs*2:hl*2}; j=$(( hs + hl )); fi; done
    elif [ "$fn" = 8 ]; then OPS+=( "$st:$ln" ); fi
    i=$(( st + ln ))
  elif [ "$wt" = 1 ]; then i=$(( i + 8 )); elif [ "$wt" = 5 ]; then i=$(( i + 4 )); fi
done

# --- fetch and place only this partition's ops ---
truncate -s "$PSIZE" "$OUTF"; fetched=0
for spec in "${OPS[@]}"; do
  st=${spec%:*}; e=$(( st + ${spec#*:} )); otype=0; doff=0; dlen=0; EXT=(); j=$st
  while [ "$j" -lt "$e" ]; do
    vhex "$PH" "$j"; t=$VV; j=$VN; ofn=$(( t >> 3 )); owt=$(( t & 7 ))
    if [ "$owt" = 0 ]; then vhex "$PH" "$j"; case "$ofn" in 1) otype=$VV;; 2) doff=$VV;; 3) dlen=$VV;; esac; j=$VN
    elif [ "$owt" = 2 ]; then vhex "$PH" "$j"; xl=$VV; xs=$VN
      if [ "$ofn" = 6 ]; then sb=0; nb=0; k=$xs; ke=$(( xs + xl ))
        while [ "$k" -lt "$ke" ]; do vhex "$PH" "$k"; et=$VV; k=$VN; efn=$(( et >> 3 )); vhex "$PH" "$k"; [ "$efn" = 1 ] && sb=$VV; [ "$efn" = 2 ] && nb=$VV; k=$VN; done
        EXT+=( "$sb:$nb" ); fi
      j=$(( xs + xl ))
    elif [ "$owt" = 1 ]; then j=$(( j + 8 )); elif [ "$owt" = 5 ]; then j=$(( j + 4 )); fi
  done
  if [ "$otype" = 6 ] || [ "$otype" = 7 ]; then continue; fi
  rget $(( DATABASE + doff )) "$dlen" "$d/blob"; fetched=$(( fetched + dlen ))
  # A full OTA mixes REPLACE, REPLACE_XZ and REPLACE_BZ in one partition, so both
  # decompressors are needed. Anything else implies a delta OTA, which has no source here.
  case "$otype" in
    0) cp "$d/blob" "$d/dec";;
    8) xz -dc "$d/blob" > "$d/dec";;
    1) bzip2 -dc "$d/blob" > "$d/dec";;
    *) echo "op type $otype needs a source partition (not a full OTA?)" >&2; exit 1;;
  esac
  dpos=0; for ex in "${EXT[@]}"; do sb=${ex%:*}; nb=${ex#*:}
    dd if="$d/dec" bs="$BLOCK" skip="$dpos" count="$nb" of="$OUTF" seek="$sb" conv=notrunc 2>/dev/null
    dpos=$(( dpos + nb )); done
done

got=$(sha256sum "$OUTF" | cut -d' ' -f1)
[ -n "$PHASH" ] || { echo "manifest carried no hash for '$PART'" >&2; exit 1; }
[ "$got" = "$PHASH" ] || { echo "sha256 mismatch vs the OTA manifest for '$PART'" >&2; exit 1; }
echo "  stock $PART: $(stat -c%s "$OUTF") bytes, fetched $(( fetched / 1048576 )) MiB, sha256 matches the manifest"
echo "  build: $BUILD"
