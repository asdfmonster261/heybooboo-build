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

	scripts/sign-boot.sh out/yogi/dist /path/to/kernel-15938155 boot-signed.img
	scripts/make-zip.sh boot-signed.img out/yogi/dist/vendor_kernel_boot.img kernel.zip

The boot.img the build gives you already has an AVB footer, which is the
misleading part: it's unsigned, sized to the wrong partition, and its
security_patch reads 2027-00-05. There is no month 00. Flash that and KeyMint
can record a patch level you can't get back from, and /data stops being
readable. sign-boot.sh erases the footer and redoes it.

boot and vendor_kernel_boot always go together and always from the same build.
Modules in the vkb ramdisk carry CRCs tied to that kernel.

Have the factory image downloaded before you flash anything. Don't write the
bootloader and don't switch slots.
