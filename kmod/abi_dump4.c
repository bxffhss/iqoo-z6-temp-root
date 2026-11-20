/* abi_dump4.c —— 让 clang 把**当前(打完布局补丁的)树**里这几个偏移的数值写进报错文本。
 * 用法与 kmod/abi_dump2.c 相同：`char (*a)[N] = 1;` ⇒ clang 报
 *   initializing 'char (*)[1680]' with an expression of incompatible type 'int'
 * 从 'char (*)[N]' 里读 N。这里只问 5 个 abi_check2 没过/被我算错的量。
 */
#include <linux/module.h>
#include <linux/sched.h>
#include <linux/stddef.h>

void abi_dump4(void)
{
	char (*mod_size)[sizeof(struct module)] = 1;
	char (*mod_exit)[offsetof(struct module, exit)] = 1;
	char (*mod_init)[offsetof(struct module, init)] = 1;
	char (*ts_pid)[offsetof(struct task_struct, pid)] = 1;
	char (*ts_comm)[offsetof(struct task_struct, comm)] = 1;
	char (*ts_seccomp)[offsetof(struct task_struct, seccomp)] = 1;
	(void)mod_size; (void)mod_exit; (void)mod_init; (void)ts_pid; (void)ts_comm; (void)ts_seccomp;
}
