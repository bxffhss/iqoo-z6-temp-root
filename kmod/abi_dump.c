/* 让编译器把实际数值写进错误信息里(clang: "cannot initialize a variable of type
 * 'char (*)[936]' with an lvalue of type 'int'") —— 比反复猜断言快得多。 */
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/stddef.h>

void abi_dump_probe(void)
{
	char (*a)[sizeof(struct module)] = 1;
	char (*b)[offsetof(struct module, name)] = 1;
	char (*c)[offsetof(struct module, init)] = 1;
	char (*d)[offsetof(struct module, exit)] = 1;
	char (*e)[sizeof(struct kprobe)] = 1;
	char (*f)[offsetof(struct kprobe, addr)] = 1;
	char (*g)[offsetof(struct kprobe, symbol_name)] = 1;
	(void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g;
}
