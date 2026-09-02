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

	scripts/release.sh out/yogi/dist /path/to/kernel-15938155 kernel.zip

That signs the boot.img and packages the zip, and leaves kernel-boot.img beside
it, which is what you RAM-boot with fastboot before writing anything. sign-boot.sh
and make-zip.sh underneath it take the same arguments if you want the steps apart.

The boot.img the build gives you already has an AVB footer, which is the
misleading part: it's unsigned, sized to the wrong partition, and its
security_patch reads 2027-00-05. There is no month 00. Flash that and KeyMint
can record a patch level you can't get back from, and /data stops being
readable. sign-boot.sh erases that footer and redoes it, then checks the result
and fails rather than printing it. The erase is only for a known starting state,
since avbtool 1.4.0 re-footers over the real payload with or without it.
avbtool's own verify_image returns 0 on a completely unsigned image, so it can't
be the whole check.

boot and vendor_kernel_boot always go together and always from the same build,
because modules in the vkb ramdisk carry CRCs tied to that kernel. make-zip.sh
takes the dist directory rather than the two images for that reason, and checks
the signed boot.img back against the one in there, so a mismatched pair won't
package.

Have the factory image downloaded before you flash anything. Don't write the
bootloader and don't switch slots.

GPL-2.0, since both patches derive from GPL-2.0 kernel source. `tools/avbtool`
is MIT and keeps its own header. AnyKernel3 isn't vendored here; make-zip.sh
fetches it at build time and the zip ships its BSD-3-Clause license alongside.
