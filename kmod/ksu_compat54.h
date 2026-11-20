/* ksu_compat54.h —— 给"面向 6.x 的 KernelSU"补 5.4 上缺的**声明类**东西（不动 KSU 源码）。
 *
 * 注入方式：make ... KCFLAGS="-include /home/lucy/ksu_compat54.h"
 * 只管三类零风险缺口：① 缺 include（`init_task`/`tasklist_lock`/`task_pgrp`/`put_task_struct`
 * 这些其实都在头文件里，KSU 只是没 include）；② 他们自建的宏 `SECCOMP_ARCH_NATIVE_NR`；
 * ③ 5.4 没有的 `*_nofault` 旧名字（5.4 叫 unsafe_*）。
 * 需要改代码才能解决的（flask.h/SSID、fsnotify 签名、TWA_RESUME、seccomp 字段名）**不在这里**，
 * 那些要按文件动，见 kmod/ROUTE-B-OFFSET-INVERSION.md §6.1 的清单。
 */
#ifndef _KSU_COMPAT54_H
#define _KSU_COMPAT54_H

#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/sched/task.h>
#include <linux/sched/task_stack.h>
#include <linux/uaccess.h>
#include <linux/pid.h>
#include <linux/cred.h>
#include <linux/fs.h>
#include <linux/nsproxy.h>
#include <linux/security.h>
#include <linux/namei.h>
#include <linux/slab.h>
/* ★TWA_* 在这棵 5.4 树里**完全不存在**(`grep TWA_ include/linux/task_work.h` 空)，
 * 因为 5.4 的 `task_work_add(task, twork, bool notify)` 第三参就是布尔；
 * 6.x 的 `TWA_RESUME` == "置 TIF_NOTIFY_RESUME 后唤醒" == 这里的 `notify=true` ⇒ 映射成 true 是等价的。
 * (先前我把它当"6.x-only 要改代码"是错的：先找定义/签名，再决定是不是移植问题。) */
#ifndef TWA_RESUME
#define TWA_RESUME true
#endif

/* ★故意**不**在这里映射 `copy_to_kernel_nofault` 和 `__p4d_to_phys`：
 * 这两处只出现在 `hook/arm64/patch_memory.c`（就是替代 `text_poke_bp` 的那块真写内核 text 的代码），
 * 语义猜错 = 直接写坏内核 ⇒ 必须先把那个文件读一遍再动，不许用宏糊过去。
 *
 * 下面三个是**用户态**的 nofault 拷贝，6.x 的契约很明确：成功 0、失败 -EFAULT。
 * 5.4 的对应物 `unsafe_copy_to_user(to, from, size, err)` 是四参数且失败 `goto err` ⇒ 不能直接映射，
 * 所以按契约自己实现（pagefault_disable + inatomic 拷贝）。 */
#include <linux/mm.h>
#include <linux/uaccess.h>

static inline int ksu_copy_to_user_nofault(void __user *to, const void *from, int len)
{
	int ret;

	pagefault_disable();
	if (access_ok(to, len))
		ret = __copy_to_user_inatomic(to, from, len) ? -EFAULT : 0;
	else
		ret = -EFAULT;
	pagefault_enable();
	return ret;
}

static inline int ksu_copy_from_user_nofault(void *to, const void __user *from, int len)
{
	int ret;

	pagefault_disable();
	if (access_ok(from, len))
		ret = __copy_from_user_inatomic(to, from, len) ? -EFAULT : 0;
	else
		ret = -EFAULT;
	pagefault_enable();
	return ret;
}

/* 6.x 返回拷贝长度(含结尾 NUL)，负数=错误；这里逐字节 inatomic 读，越界返回 -EFAULT */
static inline long ksu_strncpy_from_user_nofault(char *dst, const char __user *src, long count)
{
	long i = 0;

	if (count <= 0)
		return 0;
	if (!access_ok(src, count))
		return -EFAULT;
	pagefault_disable();
	for (; i < count; i++) {
		char c;

		if (__copy_from_user_inatomic(&c, src + i, 1)) {
			pagefault_enable();
			return -EFAULT;
		}
		dst[i] = c;
		if (!c)
			break;
	}
	pagefault_enable();
	return i + 1;
}

#define copy_to_user_nofault(to, from, len) ksu_copy_to_user_nofault((to), (from), (len))
#define copy_from_user_nofault(to, from, len) ksu_copy_from_user_nofault((to), (from), (len))
#define strncpy_from_user_nofault(dst, src, count) ksu_strncpy_from_user_nofault((dst), (src), (count))

/* 他们的宏: arm64 的 seccomp syscall 号(用于在 syscall 表里定位入口) */
#ifndef SECCOMP_ARCH_NATIVE_NR
#define SECCOMP_ARCH_NATIVE_NR __NR_seccomp
#endif
#ifndef SECCOMP_ARCH_NATIVE
#define SECCOMP_ARCH_NATIVE AUDIT_ARCH_AARCH64
#endif

/* 6.x 才有的"匿名 inode 打标签"钩子(5.14+)，本树没有。KSU 只在**自己**创建匿名 inode
 * (eventfd/pipe 一类)时问一次，返回 0 = 放行，不参与任何授权判定 ⇒ 空实现是安全的。
 * ★教训：这类补充一律在**本地这份文件**里改再整份上传；上一发我用 sed 在远端做文本手术，
 *   把文件改坏成 32 条 "expected parameter declarator"。 */
static inline int security_inode_init_security_anon(struct inode *inode,
                                                   const struct qstr *name,
                                                   const struct inode *dir)
{
	return 0;
}

/* ==== patch_memory.c（KSU 自己写的"改内核 text"层，用来替代本机不存在的 text_poke_bp）====
 * ★★这两条只是为了**过编译**，语义我按现场读出来的用法给了等价物，但上机前必须整文件复审：
 *    写错 = 写坏内核 text。见 kmod/ROUTE-B-OFFSET-INVERSION.md §6.6 的 B 堆。
 * ① `__p4d_to_phys`：本树 p4d 是**折叠层**(CONFIG_ARM64_PGTABLE_LEVELS 少一级时走
 *    asm-generic/pgtable-nop4d.h)，那里给了 `p4d_page_paddr()` ⇒ 用它就是原生写法，不是猜掩码。
 * ② `copy_to_kernel_nofault(map, src, len)`：现场只有一个调用点(patch_memory.c:150)，
 *    目的地址来自 `set_fixmap_offset(FIX_TEXT_POKE0, phy)` ⇒ 是合法内核映射，
 *    6.x 该函数的实现也就是"pagefault_disable + memcpy + 返回 0/-EFAULT"，所以 memcpy 等价。
 *    ⚠ 但 memcpy 没有 6.x 那种"访存异常被 fixup 成 -EFAULT"的保护 ⇒ 地址若算错就是 oops 而不是返回错误。
 */
/* ① `__p4d_to_phys`：本树 p4d 是**折叠层** —— `asm-generic/pgtable-nop4d.h:41` 给了
 *    `#define p4d_val(x) (pgd_val((x).pgd))`（裸硬件表项值），而 arch/arm64/include/asm/pgtable.h
 *    自己的惯例是 `__pte_to_phys(x) = (x_val(x) & PTE_ADDR_MASK)`、
 *    `__pmd_to_phys = __pte_to_phys(pmd_pte(...))`、`__pud_to_phys` 同理
 *    ⇒ 照同一惯例写，用的是**本树的掩码**，不是猜的。
 *    (先前我写 `p4d_page_paddr()` —— 本树没有这个宏，实测报 implicit declaration。) */
#ifndef __p4d_to_phys
#define __p4d_to_phys(p4d)	((phys_addr_t)(p4d_val(p4d) & PTE_ADDR_MASK))
#endif

static inline int ksu_copy_to_kernel_nofault(void *to, const void *from, size_t len)
{
	/* ★第十七发(rc19)的真根因就在这一行：**原先这里写了 `!is_vmalloc_addr(to)` 直接返回 -EFAULT**，
	 * 而本树(arm64 v3 内存布局)的 fixmap 根本不在 vmalloc 区间里：
	 *   pgtable.h:24 `VMALLOC_END = (-PUD_SIZE - VMEMMAP_SIZE - SZ_64K)`
	 *   memory.h:57-60 `PCI_IO_END = VMEMMAP_START-2M` → `PCI_IO_START = PCI_IO_END-PCI_IO_SIZE`
	 *            → `FIXADDR_TOP = PCI_IO_START-2M`  ⇒ **fixmap 在 VMALLOC_END 之上**
	 * ⇒ `set_fixmap_offset(FIX_TEXT_POKE0,...)` 的返回值必然 `>= VMALLOC_END` ⇒ 被我自己拦死
	 * ⇒ dmesg 里那句 `patch syscall 42 failed`（errno 没印出来，所以绕了十六发才定位）。
	 * 现在不做地址区间判据(区间这件事本来就不该由猜的)；"写没写在对的页上"改由
	 * `ksu_patch_text_nosync()` 里**写前比对**(map 上的当前值必须等于 dst 上的当前值)来钉，
	 * 那才是真正能证伪"phys 算错=改到别的物理页"的判据，而且它在写之前，拦下来零破坏。
	 * 长度仍然不许超过一页：memcpy 跨页时 fixmap 只映射了一页。 */
	if (unlikely(!to || !from || len == 0 || len > PAGE_SIZE))
		return -EINVAL;

	pagefault_disable();
	memcpy(to, from, len);
	if (memcmp(to, from, len) != 0) {
		pagefault_enable();
		return -EIO;
	}
	pagefault_enable();
	return 0;
}
#define copy_to_kernel_nofault(to, from, len) ksu_copy_to_kernel_nofault((to), (from), (len))

/* ==== ① 本机存在但未导出的符号：运行时解析（v3）====
 * ★两版失败的教训(md §6.11/§6.12)：
 *   v1 手抄原型 ⇒ 4 个 `conflicting types`(本树 change_pid 三参且 task 在前、kallsyms_lookup 五参含
 *      char **modname、ns_get_path 返回 void*、mntns_operations 要 const)。
 *   v2 用 `__typeof__` + **函数式宏** ⇒ 宏把*声明*也改写：
 *      `extern int ksys_unshare(unsigned long unshare_flags);` 被展开成"定义"，
 *      报 `redefinition of 'p_ksys_unshare' with a different type: 'int' vs 'int (*)(unsigned long)'`。
 *   ⇒ 定论：**函数不能用宏别名**(声明点会被改写)。改成"在 kernel/infra/dev_syms.c 里定义**同名转发函数**"，
 *     内核头里那句 extern 声明自然绑到我们的定义 ⇒ 产物里不再有这些未定义引用。
 *     只有**数据对象**用对象式宏 `(*p)`：那种展开在声明处正好得到我们需要的指针声明，
 *     且使用侧 `&x` 拿到真地址、`x.field` 拿到解引用。
 */
#include <linux/user.h>
#include <linux/pid.h>
#include <linux/kallsyms.h>
#include <linux/task_work.h>
#include <linux/proc_ns.h>
#include <linux/ns_common.h>
#include <linux/sched.h>
#include <linux/mm_types.h>
#include <linux/fs.h>

/* --- 数据对象：类型由内核头导出(__typeof__)，抄不错 --- */
extern __typeof__(init_task) *ksu_p_init_task;
#define init_task     (*ksu_p_init_task)
extern __typeof__(init_mm) *ksu_p_init_mm;
#define init_mm       (*ksu_p_init_mm)
extern __typeof__(tasklist_lock) *ksu_p_tasklist_lock;
#define tasklist_lock (*ksu_p_tasklist_lock)
extern __typeof__(mntns_operations) *ksu_p_mntns_operations;
#define mntns_operations (*ksu_p_mntns_operations)

/* selinux_blob_sizes 只在 selinux 私有头 objsec.h:151 声明(模块可见路径外) ⇒ 显式写；
 * `selinux_state` **不能**做别名：它和结构体 tag 同名(`struct selinux_state`)，预处理会连 tag 一起
 * 替换 ⇒ security.h 全崩。它仅有的 3 处使用改在 selinux/selinux.c 里显式写 ksu_p_selinux_state->…。*/
struct lsm_blob_sizes;
extern struct lsm_blob_sizes *ksu_p_selinux_blob_sizes;
#define selinux_blob_sizes (*ksu_p_selinux_blob_sizes)
struct selinux_state;
extern struct selinux_state *ksu_p_selinux_state;

int ksu_dev_syms_init(void);   /* 必须在任何使用之前调用(core/init.c 里注入) */

/* 分级闸门(md §6.26)：`insmod kernelsu.ko ksu_stage=N`，N 越大放得越开(默认 99=全开)。
 * 0=只解析符号; 2=+写 sys_call_table(dispatcher); 4=+reboot kprobe;
 * 7=+sys_enter tracepoint/setuid hook/sucompat; 8=+tracker/observer; 9=+setenforce(true) */
extern unsigned ksu_stage;
bool ksu_stage_ok(unsigned n);

/* 5 个 syscall hook 的逐位开关 + 是否允许"遍历全部任务打标"（定义与理由见 infra/dev_syms.c §7） */
extern unsigned ksu_hook_mask;
extern bool ksu_mass_mark;

/* --- 内核 tracepoint：数据符号 `__tracepoint_sys_enter` 存在但**没导出**(md §6.23/§6.24) ---
 * 树里 `register_trace_prio_sys_enter()` 是静态内联，里面写死 `&__tracepoint_sys_enter` ⇒
 * 链接期就产生未定义引用，加载报 `Unknown symbol (err -2)`。
 * ★不能"在模块里造一个同名对象"糊过去：那会让注册成功但探针永不触发 = 静默假阳。
 * 正解 = 运行时用**已导出**的 `for_each_kernel_tracepoint()` 找到真身，再调同样已导出的
 * `tracepoint_probe_register_prio()/tracepoint_probe_unregister()`。实现见 infra/dev_syms.c。 */
struct pt_regs;
struct tracepoint;
int ksu_sys_enter_tp_register(void (*probe)(void *, struct pt_regs *, long));
void ksu_sys_enter_tp_unregister(void (*probe)(void *, struct pt_regs *, long));
struct tracepoint *ksu_tracepoint_find(const char *name);

#endif /* _KSU_COMPAT54_H */
