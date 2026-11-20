#include <linux/build_bug.h>
#include <linux/module.h>
static int __init ap_init(void)
{
	/* 这两条互相矛盾：如果 BUILD_BUG_ON 真生效，必然至少一条编译失败 */
	BUILD_BUG_ON(sizeof(struct module) != 960);
	BUILD_BUG_ON(sizeof(struct module) != 896);
	return 0;
}
static void __exit ap_exit(void) {}
module_init(ap_init);
module_exit(ap_exit);
MODULE_LICENSE("GPL");
