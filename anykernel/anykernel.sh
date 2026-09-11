### AnyKernel3 script - yogi (Pixel 11 Pro Fold, Tensor G6 / malibu)

### AnyKernel setup
properties() { '
kernel.string=yogi kernel (repack) - boot only, vendor_kernel_boot left stock
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
'; } # end properties

# This zip repacks: it swaps the kernel into the device's OWN boot image and writes
# that back, so the partition keeps the AVB footer it already had. No pre-signed
# image, and vendor_kernel_boot is never touched.
#
# boot carries the security patch level only in its AVB 2.0 footer props (the boot
# header os_version is 0), and KeyMint reads that level to unwrap the version-bound
# /data keys. Drop the footer and the device lands in recovery with "Your data may
# be corrupt". mkbootimg-from-scratch drops it; magiskboot repack carries it forward
# and from v31.0 also syncs the hash descriptor size. So there is no patchlevel
# guard here: the level comes from the user's own boot, there is nothing to pin.
#
# vendor_kernel_boot stays stock. The kernel is GKI with a frozen KMI, so the stock
# vendor modules load against it unchanged and writing it is unnecessary.
#
# magiskboot here is the arm64 v31.0 build. AK3 ships a 32-bit one that cannot run
# on this 64-bit-only device; make-zip.sh swaps it in and asserts the arch.

# shell variables
BLOCK=boot;
IS_SLOT_DEVICE=1;

# In a recovery like OrangeFox the toolbox getprop is a symlink that needs
# LD_LIBRARY_PATH, which AK3 unsets, so getprop ro.boot.slot_suffix returns empty and
# setup_ak below aborts with "Unable to determine active slot". The slot lives in
# /proc/bootconfig as androidboot.slot_suffix regardless. Override getprop to read boot
# props from there before ak3-core resolves the slot; anything else falls through to the
# real binary, which works in a booted flasher.
getprop() {
  local k="$1" v;
  case "$k" in
    ro.boot.*)
      v=$(grep "^androidboot.${k#ro.boot.} = " /proc/bootconfig 2>/dev/null | cut -d'"' -f2);
      [ "$v" ] && { echo "$v"; return 0; };;
  esac;
  /system/bin/getprop "$@" 2>/dev/null;
}

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

MB=$AKHOME/tools/magiskboot;
IMAGE=$AKHOME/Image;
IMAGESHA=__IMAGESHA__;
BKDIR=/data/local/tmp;
WORK=$AKHOME/repack;

sha_of() { $bb sha256sum "$1" 2>/dev/null | $bb cut -d' ' -f1; }

# magiskboot returns non-error, non-zero codes for some image kinds (3 for
# vendor_boot); a plain boot.img unpacks 0. Only 1 is a real failure.
mb() { local rc=0; "$MB" "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" != 1 ]; }

# an AVB-footered image ends with a 64-byte footer whose magic is "AVBf".
has_avb_footer() {
  local n; n=$($bb wc -c < "$1");
  [ "$n" -gt 64 ] || return 1;
  [ "$($bb dd if="$1" bs=1 skip=$((n - 64)) count=4 2>/dev/null)" = "AVBf" ];
}

# AK3's own do.devicecheck reads getprop/build.prop, which is unreliable in a
# recovery like OrangeFox: it unsets LD_LIBRARY_PATH (breaking the toolbox getprop
# symlink), then falls back to build.prop paths that do not match the recovery
# mount layout, and rejects a yogi as unsupported. /proc/bootconfig carries
# androidboot.hardware with no mount, getprop or LD_LIBRARY_PATH needed anywhere.
check_device() {
  local dev;
  dev=$($bb grep '^androidboot.hardware = ' /proc/bootconfig 2>/dev/null | $bb cut -d'"' -f2);
  [ "$dev" ] || dev=$($bb sed -n 's/.*androidboot\.hardware=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null);
  [ "$dev" ] || dev=$(getprop ro.product.device 2>/dev/null);
  [ "$dev" = yogi ] || abort "  ! device is '${dev:-unknown}', not yogi. Aborting.";
}

ui_print " ";
ui_print "  yogi kernel (repack)";
ui_print "  swaps the kernel into your own boot, keeps its AVB footer";
ui_print "  vendor_kernel_boot is left stock";
ui_print " ";
ui_print "  slot   : ${SLOT:-none}";

check_device;
ui_print "  device : yogi";

[ -f "$IMAGE" ] || abort "  ! Image missing from zip. Aborting.";
[ "$(sha_of "$IMAGE")" = "$IMAGESHA" ] || abort "  ! Image checksum mismatch - zip is corrupt or modified. Aborting.";
ui_print "  kernel : checksum OK";

[ -e "$BLOCK" ] || abort "  ! boot partition not found ($BLOCK). Aborting.";

$bb rm -rf "$WORK"; $bb mkdir -p "$WORK";

# Pull the live boot and refuse to touch it unless it carries an AVB footer.
# Repacking a footerless boot would strip the patch level and break /data.
$bb dd if="$BLOCK" of="$WORK/boot.img" bs=1048576 2>/dev/null || abort "  ! could not read boot. Aborting.";
has_avb_footer "$WORK/boot.img" || abort "  ! current boot has no AVB footer - refusing to repack. Aborting.";
BOOTSZ=$($bb wc -c < "$WORK/boot.img");

# Back up the live boot before writing. Slot A on this device holds an older build
# with no userspace under Virtual A/B, so it is not a fallback: this backup and
# fastboot are the only ways back.
bk=$BKDIR/boot-before.img;
if [ ! -f "$bk" ]; then
  if $bb dd if="$BLOCK" of="$bk" bs=1048576 2>/dev/null; then
    ui_print "  backup : $bk";
  else
    abort "  ! refusing to write without a backup. Aborting.";
  fi;
else
  ui_print "  backup : $bk (kept existing)";
fi;

# Only the kernel changes; ramdisk (none here), dtb, header and footer are carried
# over by magiskboot.
cd "$WORK";
mb unpack boot.img || abort "  ! unpack failed. Aborting.";
$bb cp -f "$IMAGE" kernel || abort "  ! could not stage kernel. Aborting.";
mb repack boot.img new-boot.img || abort "  ! repack failed. Aborting.";
[ -f new-boot.img ] || abort "  ! repack produced no image. Aborting.";
has_avb_footer new-boot.img || abort "  ! repacked boot lost its AVB footer. Aborting.";

# boot is a chained AVB partition and must fill it exactly. magiskboot pads the
# repack to the source size, so this equals the partition; guard it anyway.
NEWSZ=$($bb wc -c < new-boot.img);
[ "$NEWSZ" = "$BOOTSZ" ] || abort "  ! repacked size $NEWSZ != boot $BOOTSZ. Aborting.";

ui_print "  writing boot ($NEWSZ bytes)...";
$bb dd if=new-boot.img of="$BLOCK" bs=1048576 || abort "  ! boot write failed. Aborting.";
$bb sync;

# Read the flashed boot back and compare the kernel to the shipped one.
$bb rm -rf "$WORK/verify"; $bb mkdir -p "$WORK/verify";
$bb dd if="$BLOCK" of="$WORK/verify/boot.img" bs=1048576 2>/dev/null;
cd "$WORK/verify";
mb unpack boot.img || abort "  ! read-back unpack failed. Aborting.";
if [ "$(sha_of kernel)" = "$IMAGESHA" ]; then
  ui_print "  verify : OK";
else
  ui_print "  verify : MISMATCH";
  ui_print "    restore with:";
  ui_print "    dd if=$bk of=$BLOCK bs=1048576";
  abort "  ! verification failed. Aborting.";
fi;

$bb rm -rf "$WORK";

ui_print " ";
ui_print "  Done. Reboot to run the new kernel.";
ui_print " ";
ui_print "  Backup is at $bk - pull it to a PC now:";
ui_print "    adb pull $bk";
ui_print "  It lives on /data, which is what breaks if a boot goes wrong.";
ui_print " ";
ui_print "  If it does not boot, from fastboot flash a stock boot:";
ui_print "    fastboot flash boot$SLOT <stock boot.img>";
ui_print "  Do NOT change slots and do NOT flash the bootloader.";
ui_print " ";
