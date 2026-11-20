/* 取 struct kprobe 的 handler 偏移。前提(已在真机验证)：
 *   sizeof=136、addr@40、symbol_name@48 三值在"设备实测"与"树算出"两边一致
 *   ⇒ struct kprobe 没被厂商改过 ⇒ 它的其余字段偏移可以照树用。 */
#include <linux/kprobes.h>
#include <linux/stddef.h>

void abi_dump3(void)
{
	char (*a)[offsetof(struct kprobe, pre_handler)] = 1;
	char (*b)[offsetof(struct kprobe, post_handler)] = 1;
	char (*c)[offsetof(struct kprobe, fault_handler)] = 1;
	char (*d)[offsetof(struct kprobe, flags)] = 1;
	char (*e)[offsetof(struct kprobe, kp)] = 1;
	char (*f)[offsetof(struct kprobe, opcode)] = 1;
	char (*g)[offsetof(struct kprobe, offset)] = 1;
	(void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g;
}
