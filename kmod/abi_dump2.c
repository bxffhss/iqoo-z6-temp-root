/* 让编译器把**实际数值**写进诊断（`char (*a)[N] = 1;` 会报 "char (*)[N]"）。
 * 对表(设备真机实测, analysis/GHOST-CRED-SWEEP-20260928.md)：
 *   task_struct->cred = 0x848   cred->security = 0x24   cred->fsgid = 0x20
 * 这几条是 KSU 会直接读的字段；对不上就说明厂商也改过这些结构体 ⇒ 路线 B 必须要厂商源码。 */
#include <linux/cred.h>
#include <linux/fs.h>
#include <linux/nsproxy.h>
#include <linux/sched.h>
#include <linux/sched/types.h>
#include <linux/stddef.h>

void abi_dump2(void)
{
	char (*a)[offsetof(struct task_struct, cred)] = 1;
	char (*b)[offsetof(struct cred, security)] = 1;
	char (*c)[offsetof(struct cred, fsgid)] = 1;
	char (*d)[offsetof(struct task_struct, pid)] = 1;
	char (*e)[offsetof(struct task_struct, comm)] = 1;
	char (*f)[offsetof(struct task_struct, files)] = 1;
	char (*g)[offsetof(struct task_struct, nsproxy)] = 1;
	char (*h)[sizeof(struct cred)] = 1;
	(void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; (void)h;
}
