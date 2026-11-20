// SPDX-License-Identifier: GPL-2.0
/* infra/seccomp_cache.c —— **本机版：整文件替换成空操作**(md §6.24)
 *
 * 上游这个文件自己**重新定义**了一份 `struct seccomp_filter`，然后按
 *   refs / users / log / **struct action_cache cache** / prev / prog / notif / ...
 * 的布局对 `filter->cache.allow_native` 那个 292 位位图做 set_bit/clear_bit，
 * 意图是"绕过 seccomp 的 BPF 快查表"让 allowlisted app 也能调 reboot 拿驱动 fd。
 *
 * ★本机的真身(一手 grep 厂商树 kernel/seccomp.c:139)是**另一个布局**：
 *   struct seccomp_filter { refcount_t usage; bool log; struct seccomp_filter *prev;
 *                           struct bpf_prog *prog; struct notification *notif;
 *                           struct mutex notify_lock; };
 * —— **压根没有 action cache**(那是 Android 早期补丁，5.4 之前的内核里被删了；
 *   全树搜 action_cache/allow_native/SECCOMP_ARCH_NATIVE_NR 三处命中数 = 0)。
 *
 * ⇒ 若照上游跑：set_bit(142, ...) 会往这个 ~48 字节对象的**偏移 16 起写 48 字节**，
 *   覆盖 prev/prog/notif/notify_lock 并**越过分配末尾**写进相邻 slab = 堆破坏。
 *   触发点 = `hook/setuid_hook.c:32/44`(zygote 给 allowlisted uid setresuid 时)，
 *   也就是说**一发 su 就会踩**，而这正是本次上机要做的事 ⇒ 必须先中性化。
 *
 * 语义代价(如实记录)：普通 app 里那条"用 reboot magic 拿一份**普通** ksu fd"的路没了。
 *   - su 提权本身**不依赖它**：`feature/sucompat.c` 的 execve hook 在内核态直接调
 *     `escape_with_root_profile()`，成功后再 `ksu_install_su_fd()` 塞一个 **su-session fd**，
 *     全程不需要用户态能调 reboot(§6.20 的 app 域 SIGSYS 结论因此不影响 su 路径)。
 *   - 丢的是"app 主动做 GET_INFO/SET_SEPOLICY 这类普通 fd 调用"，对 we 的白名单模型非必需。
 * 保持导出符号不变(签名逐字照上游)，调用点一行都不用改。 */
#include <linux/sched.h>
#include <linux/seccomp.h>
#include <linux/printk.h>
#include "infra/seccomp_cache.h" /* 用上游那份声明，保证签名一字不差 */

struct seccomp_filter; /* 只取指针类型，永不解引用 */

void ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr)
{
	(void)filter;
	(void)nr;
}

void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr)
{
	pr_info_once("seccomp_cache: 本机内核没有 seccomp action cache，空操作(避免按错布局写堆)\n");
	(void)filter;
	(void)nr;
}
