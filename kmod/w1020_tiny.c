// w1020_tiny.c —— 极简件：只为回答"这台机能不能装**任何**第二个模块"。
// init 里唯一动作是 pr_info 一行 + 一个可读参数；不解析策略、不查符号、不建 slab、不碰 /proc。
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/moduleparam.h>
#include <linux/export.h>
#include <linux/types.h>
MODULE_LICENSE("GPL");
MODULE_AUTHOR("z6");
MODULE_DESCRIPTION("tiny load-path probe: can a second module be inserted at all?");
static int tiny_alive = 1;	module_param(tiny_alive, int, 0444);
static int __init tiny_init(void)
{
	pr_info("W1020 TINY init ran alive=%d\n", tiny_alive);
	return 0;
}
static void __exit tiny_exit(void) { pr_info("W1020 TINY exit\n"); }
module_init(tiny_init);
module_exit(tiny_exit);
// ★同样带 CFI 桩(与 v4 同一变量之外的常量)：本件要测的是"装载动作"，不该因为缺桩多一个失败因
void __cfi_check(uint64_t id, void *ptr, void *diag) { (void)id; (void)ptr; (void)diag; }
