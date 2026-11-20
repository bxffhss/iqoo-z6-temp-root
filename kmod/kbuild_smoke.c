// kbuild_smoke.c — 用**真 kbuild**(而不是手搓 asm)编一个会调 printk 的模块，
// 验证两件事：
//   1) 把我们离线抽的 Module.symvers_dev 塞进构建树 ⇒ 产出的 __versions 里 CRC 与设备一致；
//   2) vermagic 能不能凑成设备那一串(5.4.281-qgki-g2a88cd145def ...)。
// 这两条都对，"拿这棵树编 KSU"才算真的通。判据由 kmod/check_ko.py 在本地跑。
#include <linux/init.h>
#include <linux/module.h>
#include <linux/printk.h>

static int __init kbuild_smoke_init(void)
{
	pr_info("kbuild_smoke: 真 kbuild + 离线 symvers 产出的模块\n");
	return 0;
}

static void __exit kbuild_smoke_exit(void)
{
	pr_info("kbuild_smoke: exit\n");
}

module_init(kbuild_smoke_init);
module_exit(kbuild_smoke_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("kbuild + offline Module.symvers smoke test");
