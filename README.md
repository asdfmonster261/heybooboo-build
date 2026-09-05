# heybooboo-build

Patches and scripts for building the yogi kernel. The kernel is in
[heybooboo-kernel](https://github.com/asdfmonster261/heybooboo-kernel); this is
the rest of it, which exists mostly because Google ships the device tree and the
out-of-tree modules in the GPL tarball and publishes them nowhere.

You need that tarball for CD1A.260714.001.A9, from
https://source.android.com/opensourcerequest. Extract `kernel-15938155.tar.xz`
somewhere with 25 GB free, then drop a checkout of heybooboo-kernel over
`common/gki`.

	scripts/apply-patches.sh /path/to/kernel-15938155
	cd /path/to/kernel-15938155 && ./build_yogi.sh --nouse_prebuilt_kernel

The patches fix two things that only break on 6.12.92. bcmdhd's
MAC_ADDR_STR_LEN collides with the one if_ether.h picked up, at a different
value, and vh_sched still carries its own attach_task()/attach_one_task(), which
moved into sched.h. Reasons are in the patch headers.

Don't pass `--lto=none`, it's already the default.

## Packaging

	scripts/release.sh out/yogi/dist/boot.img kernel.zip

The zip repacks. It swaps the built kernel into the boot image already on the
phone, with magiskboot, and writes that back, so the boot partition keeps its own
AVB footer and its own patch level. It leaves vendor_kernel_boot alone, because
the kernel is GKI with a frozen KMI and the stock vendor modules load against it
unchanged. Nothing is signed and nothing is pinned, so one zip flashes on whatever
build the device happens to be on.

release.sh pulls the kernel out of the boot.img, runs verify-repack.sh, then
make-zip.sh. verify-repack.sh repacks the kernel into a stock boot and checks the
footer came through: the patch-level props match the stock boot and the image size
tracks the new kernel. It defaults to `../yogi_boot_img/boot.img`; pass another as
a third argument. make-zip.sh ships the raw Image plus an arm64 magiskboot and
busybox from a pinned Magisk release, since AnyKernel3's own tools are 32-bit and
this device is 64-bit only. magiskboot has to be v31.0 or newer: older builds
leave the boot's hash descriptor image size stale.

The zip reads the device name and the active slot from /proc/bootconfig rather
than getprop, so it flashes from KernelFlasher and from a recovery like OrangeFox,
where AnyKernel3's getprop path comes back empty.

## The pre-signed fallback

The older approach writes two complete, pre-signed images with dd instead of
repacking. It is kept under the -dd names, plus sign-boot.sh and verify-boot.sh.

	scripts/release-dd.sh out/yogi/dist /path/to/kernel-15938155 kernel.zip

It signs the boot.img and packages the zip, and leaves kernel-boot.img beside it,
which is what you RAM-boot with fastboot before writing anything. The boot.img the
build gives you already has an AVB footer, which is the misleading part: it's
unsigned, sized to the wrong partition, and its security_patch reads 2027-00-05.
There is no month 00. Flash that and KeyMint can record a patch level you can't
get back from, and /data stops being readable. sign-boot.sh erases that footer and
redoes it, then checks the result and fails rather than printing it. avbtool's own
verify_image returns 0 on a completely unsigned image, so it can't be the whole
check. In this path boot and vendor_kernel_boot go together and from the same
build, because the vkb modules carry CRCs tied to that kernel, and make-zip-dd.sh
checks the signed boot back against the dist so a mismatched pair won't package.

Have the factory image downloaded before you flash anything. Don't write the
bootloader and don't switch slots.

GPL-2.0, since both patches derive from GPL-2.0 kernel source. `tools/avbtool`
is MIT and keeps its own header. AnyKernel3 isn't vendored here; make-zip.sh
fetches it at build time and the zip ships its BSD-3-Clause license alongside.
