/* d5.c —— 问"未打补丁的树"里 struct module 的真实尺寸与三个偏移(靠 clang 把数值写进诊断)。 */
#include <linux/module.h>
#include <linux/stddef.h>

void d5(void)
{
	char (*a)[sizeof(struct module)] = 1;
	char (*b)[offsetof(struct module, name)] = 1;
	char (*c)[offsetof(struct module, init)] = 1;
	char (*d)[offsetof(struct module, exit)] = 1;
	char (*e)[offsetof(struct module, core_layout)] = 1;
	(void)a; (void)b; (void)c; (void)d; (void)e;
}
