### AnyKernel3 script - yogi (Pixel 11 Pro Fold, Tensor G6 / malibu)

### AnyKernel setup
properties() { '
kernel.string=yogi kernel - boot + vendor_kernel_boot pair
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=yogi
supported.versions=17
supported.patchlevels=2026-08 - 2026-08
'; } # end properties

# This zip does NOT repack anything. It writes two complete, pre-signed images.
#
# boot on this device carries no ramdisk (ramdisk_size=0); the generic ramdisk
# lives in init_boot. More importantly boot is a *chained* AVB partition: vbmeta
# declares "Chain Partition descriptor: boot", so libavb loads boot's own vbmeta
# from the end of the boot partition. The boot header's os_version field is 0,
# so the security patch level exists only as AVB footer properties. Repacking
# drops that footer, the bootloader then reports patch level 0, KeyMint cannot
# unwrap the version-bound /data keys, and the device lands in recovery with
# "Your data may be corrupt". AnyKernel3 ships no avbtool and its signer is
# AVB v1, which this device does not use - so dump_boot/write_boot and
# split_boot/flash_boot are all unusable here.
#
# boot.img is therefore signed on the build host with avbtool add_hash_footer
# and padded to the full 67108864-byte partition, footer last.
#
# vendor_kernel_boot is NOT chained - it is covered by a hash descriptor in the
# main vbmeta with an explicit image size - so it needs no footer and ships at
# its natural size.
#
# supported.patchlevels pins 2026-08 exactly, in both directions. Flashing an
# older SPL than the keys expect breaks /data. Flashing a NEWER one binds
# KeyMint upward and strands the stock image, which is just as bad. Rebuild and
# re-sign for the new level after an OTA rather than flashing this zip.

# shell variables
BLOCK=boot;
IS_SLOT_DEVICE=1;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

BOOTIMG=$AKHOME/boot.img;
VKBIMG=$AKHOME/vendor_kernel_boot.img;
BOOTSHA=f6b9fbdc656ecf1e80dcd7e3ff6a2527cd360cf2e813a45441fa4e51740c27f3;
VKBSHA=78a532713ef9f7877d50f5da90b32702b70f81781f2aa2ffaeddf622a6388d65;
BKDIR=/data/local/tmp;

sha_of() { $bb sha256sum "$1" 2>/dev/null | $bb cut -d' ' -f1; }

# Both images come from one build and must be flashed together: modules loaded
# from the vendor_kernel_boot ramdisk carry symbol CRCs tied to the kernel.
check_img() {
  [ -f "$1" ] || abort "  ! $2 missing from zip. Aborting.";
  if [ "$(sha_of "$1")" != "$3" ]; then
    abort "  ! $2 checksum mismatch - zip is corrupt or modified. Aborting.";
  fi;
}

ui_print " ";
ui_print "  yogi kernel";
ui_print "  writes boot AND vendor_kernel_boot";
ui_print " ";
ui_print "  slot   : ${SLOT:-none}";

check_img "$BOOTIMG" "boot.img" "$BOOTSHA";
check_img "$VKBIMG" "vendor_kernel_boot.img" "$VKBSHA";
ui_print "  images : checksums OK";

# $BLOCK was resolved to the active slot's boot partition by setup_ak above.
# Derive the vendor_kernel_boot path from it so we inherit the same by-name dir.
VKBLOCK=$($bb dirname "$BLOCK")/vendor_kernel_boot$SLOT;
[ -e "$BLOCK" ] || abort "  ! boot partition not found ($BLOCK). Aborting.";
[ -e "$VKBLOCK" ] || abort "  ! vendor_kernel_boot not found ($VKBLOCK). Aborting.";

# write_part <image> <block> <label> <require_exact_size>
write_part() {
  local img="$1" blk="$2" label="$3" exact="$4";
  local isz psz bk wsha isha;
  isz=$($bb wc -c < "$img");
  psz=$($bb blockdev --getsize64 "$blk" 2>/dev/null);

  if [ "$exact" = "1" ] && [ "$psz" ] && [ "$psz" != "$isz" ]; then
    abort "  ! $label size mismatch: partition $psz vs image $isz. Aborting.";
  fi;

  # Back up first. Slot A on this device holds an older build and no userspace
  # under Virtual A/B, so it is not a fallback - this backup and fastboot are
  # the only ways back.
  bk=$BKDIR/$label-before.img;
  if [ ! -f "$bk" ]; then
    if $bb dd if="$blk" of="$bk" bs=1048576 2>/dev/null; then
      ui_print "  backup : $bk";
    else
      ui_print "  backup : FAILED";
      abort "  ! refusing to write $label without a backup. Aborting.";
    fi;
  else
    ui_print "  backup : $bk (kept existing)";
  fi;

  ui_print "  writing $label ($isz bytes)...";
  $bb dd if="$img" of="$blk" bs=1048576 || abort "  ! $label write failed. Aborting.";
  $bb sync;

  # Read back exactly as many bytes as we wrote and compare.
  wsha=$($bb dd if="$blk" bs="$isz" count=1 2>/dev/null | $bb sha256sum | $bb cut -d' ' -f1);
  isha=$(sha_of "$img");
  if [ "$wsha" = "$isha" ]; then
    ui_print "  verify : OK";
  else
    ui_print "  verify : MISMATCH";
    ui_print "    restore with:";
    ui_print "    dd if=$bk of=$blk bs=1048576";
    abort "  ! $label verification failed. Aborting.";
  fi;
}

write_part "$BOOTIMG" "$BLOCK"   "boot"               1;
write_part "$VKBIMG"  "$VKBLOCK" "vendor_kernel_boot" 0;

ui_print " ";
ui_print "  Done. Reboot to run the new kernel.";
ui_print " ";
ui_print "  Backups are in $BKDIR - pull them to a PC now:";
ui_print "    adb pull $BKDIR/boot-before.img";
ui_print "    adb pull $BKDIR/vendor_kernel_boot-before.img";
ui_print "  They live on /data, which is exactly what breaks if a";
ui_print "  patch-level mismatch goes wrong.";
ui_print " ";
ui_print "  If it does not boot, from fastboot:";
ui_print "    fastboot flash boot$SLOT <stock boot.img>";
ui_print "    fastboot flash vendor_kernel_boot$SLOT <stock vendor_kernel_boot.img>";
ui_print "  Do NOT change slots and do NOT flash the bootloader.";
ui_print " ";
