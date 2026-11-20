// SPDX-License-Identifier: GPL-2.0
/* dev_syms.c —— 本机**存在但未导出**内核符号的运行时解析层（路线 B 的 ①，v3；md §6.11/§6.12）。
 *
 * 机制：为每个符号在**本模块内定义同名转发函数** ⇒ 内核头里那句 `extern T f(...)` 声明绑到我们的
 * 定义，链接期不再产生未定义引用；函数体只做"指针已解析就调，没解析就保守失败"。
 * ★原型一律逐字抄自本树的声明/定义行，不凭记忆：
 *   alloc_uid / free_uid        include/linux/user.h
 *   change_pid                  include/linux/pid.h:98   (三参, task 在前!)
 *   ksys_unshare                kernel/fork.c:2902
 *   set_fs_pwd                  fs/fs_struct.c:34
 *   ns_get_path                 include/linux/proc_ns.h:79 (返回 void *)
 *   task_work_add               include/linux/task_work.h  (第三参是 bool, 不是 TWA_*)
 *   kallsyms_lookup             include/linux/kallsyms.h:88 (五参, 含 char **modname)
 *   kallsyms_lookup_name        include/linux/kallsyms.h
 *   kallsyms_lookup_size_offset include/linux/kallsyms.h:84
 *   ext4_unregister_sysfs       fs/ext4/ext4.h:3296
 * 数据对象(init_task/init_mm/tasklist_lock/selinux_state/selinux_blob_sizes/mntns_operations)
 * 不是函数，用指针 + 别名宏(见 ksu_compat54.h)。
 *
 * 地址来源 = `register_kprobe(symbol_name)` 读 `kp.addr`：本机真机实测过的招
 * (struct kprobe 136/addr@40/symbol_name@48；解析值与离线 kallsyms + 本 boot slide 三方互咬)。
 * ★兜底原则：未解析时返回负值/NULL/什么都不做，绝不返回"成功"骗过调用者。 */
#include <linux/kprobes.h>
#include <linux/err.h>
#include <linux/module.h>
#include <linux/uidgid.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/fs.h>
#include <linux/uaccess.h>   /* rc38：probe_kernel_read 的声明(原来这 include 在文件后半段，新函数在它之前) */
#include <linux/proc_fs.h>   /* rc40：proc_create 的声明 —— 和 rc38 同一个坑，别再犯第二次(见 §6.86) */
#include <linux/namei.h>     /* rc44：kern_path / inode_permission / MAY_OPEN(开文件二分探针) */
#include <linux/kernel.h>    /* rc40：vscnprintf / va_list(/proc/ksu_slots 快照要用) */
#include <linux/lsm_hooks.h> /* rc41：struct security_hook_heads / security_hook_list 的**真实布局**(要走 offsetof) */
#include <linux/mm_types.h>
#include <linux/pid.h>
#include <linux/proc_ns.h>
#include <linux/kallsyms.h>
#include <linux/task_work.h>
#include <linux/user.h>
#include <linux/stddef.h>
#include "uapi/app_profile.h" /* 授权名单文件的记录格式(与 cm57/ksuctl 生成端对表) */

/* ===== 0) 数据对象指针的定义(类型来自别名宏可见的 typeof) ===== */
__typeof__(ksu_p_init_task) ksu_p_init_task;
__typeof__(ksu_p_init_mm) ksu_p_init_mm;
__typeof__(ksu_p_tasklist_lock) ksu_p_tasklist_lock;
__typeof__(ksu_p_selinux_state) ksu_p_selinux_state;
__typeof__(ksu_p_selinux_blob_sizes) ksu_p_selinux_blob_sizes;
__typeof__(ksu_p_mntns_operations) ksu_p_mntns_operations;

/* ===== 1) 函数指针(只在本文件可见) ===== */
static __typeof__(alloc_uid) *p_alloc_uid;
static __typeof__(free_uid) *p_free_uid;
static __typeof__(change_pid) *p_change_pid;
static int (*p_ksys_unshare)(unsigned long unshare_flags);
static void (*p_set_fs_pwd)(struct fs_struct *fs, const struct path *path);
static __typeof__(ns_get_path) *p_ns_get_path;
static __typeof__(task_work_add) *p_task_work_add;
/* rc47：`is_module_text_address()` 在本机 Module.symvers 里**没有**(构建闸门一手报"未导出")
 *   ⇒ 直接引用会让 insmod 以未知符号失败。走这个文件既有的路子：只按名字解析地址、
 *   通过函数指针调用，不产生链接期引用。 */
static int (*p_is_module_text_address)(unsigned long addr);
static __typeof__(kallsyms_lookup) *p_kallsyms_lookup;
static __typeof__(kallsyms_lookup_name) *p_kallsyms_lookup_name;
static __typeof__(kallsyms_lookup_size_offset) *p_kallsyms_lookup_size_offset;
static void (*p_ext4_unregister_sysfs)(struct super_block *sb);

/* ===== 2) 取地址：文本符号 kprobe 能取，**数据符号 kprobe 取不到** =====
 * 上一版的坑(md §6.24)：`register_kprobe()` 走 `check_kprobe_address_safe()`，要求地址是
 * 内核/模块**文本**；而 init_task/init_mm/tasklist_lock/selinux_state/selinux_blob_sizes/
 * mntns_operations 在本机 kallsyms 里是 D/B(数据) ⇒ 那 6 条必然 err -EINVAL，
 * 表现就是 dev_syms 报 missing=6 并把 NULL 交给调用方。
 * 正解：先用 kprobe 取到**文本**符号 `kallsyms_lookup_name`(本机 T，且它没导出)，
 * 之后所有名字都问它 —— 本机 CONFIG_KALLSYMS_ALL=y ⇒ 数据符号它也认。 */
static unsigned long ksu_kp_lookup(const char *name)
{
	struct kprobe kp = { .symbol_name = name };
	int ret = register_kprobe(&kp);
	unsigned long addr;

	if (ret < 0) {
		pr_warn("dev_syms: register_kprobe(%s)=%d\n", name, ret);
		return 0;
	}
	addr = kp.addr;
	unregister_kprobe(&kp);
	return addr;
}

static unsigned long ksu_sym_addr(const char *name)
{
	unsigned long addr = 0;

	if (!p_kallsyms_lookup_name)
		p_kallsyms_lookup_name = (void *)ksu_kp_lookup("kallsyms_lookup_name");
	if (p_kallsyms_lookup_name)
		addr = p_kallsyms_lookup_name(name);
	if (!addr)
		addr = ksu_kp_lookup(name);	/* 退化成只认文本符号的老办法 */
	if (!addr)
		pr_warn("dev_syms: %s 取不到地址\n", name);
	return addr;
}

/* ===== 3) 同名转发函数(内核头的 extern 声明绑到这里) ===== */
struct user_struct *alloc_uid(kuid_t uid)
{
	return p_alloc_uid ? p_alloc_uid(uid) : ERR_PTR(-ENOSYS);
}

void free_uid(struct user_struct *up)
{
	if (p_free_uid && up)
		p_free_uid(up);
	else
		pr_info_once("ksu: free_uid unresolved\n");
}

void change_pid(struct task_struct *task, enum pid_type type, struct pid *pid)
{
	if (p_change_pid)
		p_change_pid(task, type, pid);
	else
		pr_info_once("ksu: change_pid unresolved\n");
}

int ksys_unshare(unsigned long unshare_flags)
{
	return p_ksys_unshare ? p_ksys_unshare(unshare_flags) : -ENOSYS;
}

void set_fs_pwd(struct fs_struct *fs, const struct path *path)
{
	if (p_set_fs_pwd)
		p_set_fs_pwd(fs, path);
	else
		pr_info_once("ksu: set_fs_pwd unresolved\n");
}

void *ns_get_path(struct path *path, struct task_struct *task,
		  const struct proc_ns_operations *ns_ops)
{
	return p_ns_get_path ? p_ns_get_path(path, task, ns_ops) : ERR_PTR(-ENOSYS);
}

int task_work_add(struct task_struct *task, struct callback_head *twork, bool notify)
{
	return p_task_work_add ? p_task_work_add(task, twork, notify) : -ENOSYS;
}

const char *kallsyms_lookup(unsigned long addr, unsigned long *symbolsize,
			    unsigned long *offset, char **modname, char *namebuf)
{
	return p_kallsyms_lookup ? p_kallsyms_lookup(addr, symbolsize, offset, modname, namebuf)
				 : NULL;
}

unsigned long kallsyms_lookup_name(const char *name)
{
	/* ★这一条是上一发加载失败(-ENOENT)的根因假设与修法：
	 * KSU 自己的 symbol resolver 会在 `ksu_init()` 里**很早**就用 kallsyms_lookup_name，
	 * 那时 ksu_dev_syms_init() 还没跑(它挂在 core/init.c 的 apply_kernelsu_rules 之前) ⇒
	 * 我们返回 0 ⇒ 调用方当成"符号不存在" ⇒ 整个加载以 -ENOENT 失败。
	 * 修法与调用顺序无关：kallsyms_lookup_name **自己就能用 kprobe 现取**(不需要解析自己)。 */
	if (p_kallsyms_lookup_name)
		return p_kallsyms_lookup_name(name);
	return ksu_kp_lookup(name);
}

int kallsyms_lookup_size_offset(unsigned long addr, unsigned long *symbolsize,
				unsigned long *offset)
{
	return p_kallsyms_lookup_size_offset
		? p_kallsyms_lookup_size_offset(addr, symbolsize, offset) : -ENOSYS;
}

void ext4_unregister_sysfs(struct super_block *sb)
{
	if (p_ext4_unregister_sysfs)
		p_ext4_unregister_sysfs(sb);
	else
		pr_info_once("ksu: ext4_unregister_sysfs unresolved\n");
}

/* ===== 4b) 第二发窗口点名的 3 个"存在但未导出"引用(md §6.23) =====
 * 内核加载时报 `Unknown symbol (err -2)` ⇒ finit_module 直接 -ENOENT。
 * 仍是"本模块内定义同名转发函数 + kprobe 现取地址"(与调用顺序无关)。
 * 签名逐字抄自本树：`__set_fixmap(idx, phys, flags)`(asm-generic/fixmap.h) 与
 * arch/arm64 的 syscall 包装 `long __arm64_sys_X(const struct pt_regs *)`。 */
/* ★原型逐字取自本树 arch/arm64/include/asm/fixmap.h:109
 *   `extern void __set_fixmap(enum fixed_addresses idx, phys_addr_t phys, pgprot_t prot);`
 * —— 上一版写成 (unsigned, unsigned long, unsigned long)，编译器直接
 * `conflicting types for '__set_fixmap'` 拒掉(2026-09-30 rc10 第一次尝试)。
 * 用 `__typeof__(__set_fixmap)` 取指针类型 = 永远与本树声明一致，不靠人记。 */
static __typeof__(__set_fixmap) *p__set_fixmap;
static long (*p__arm64_sys_close)(const struct pt_regs *regs);
static long (*p__arm64_sys_setns)(const struct pt_regs *regs);

void __set_fixmap(enum fixed_addresses idx, phys_addr_t phys, pgprot_t prot)
{
	if (p__set_fixmap)
		p__set_fixmap(idx, phys, prot);
	else
		pr_info_once("ksu: __set_fixmap unresolved\n");
}

long __arm64_sys_close(const struct pt_regs *regs)
{
	return p__arm64_sys_close ? p__arm64_sys_close(regs) : -ENOSYS;
}

long __arm64_sys_setns(const struct pt_regs *regs)
{
	return p__arm64_sys_setns ? p__arm64_sys_setns(regs) : -EINVAL;
}

/* ★`__tracepoint_sys_enter` 是**数据符号**(tracepoint 对象本身)，不能照样转发：
 * 自己定义同名对象会让 tp_marker "注册成功但永不触发" = 静默假阳(最坏的一类)。
 * 正解在下面 §4c：运行时用**已导出的** for_each_kernel_tracepoint() 拿真身。 */

/* ===== 4c) 内核 tracepoint 的运行时发现(md §6.24) =====
 * 三个用到的函数在本机都是 `T` 且**都在 Module.symvers 里**(CRC 逐条核过)：
 *   for_each_kernel_tracepoint       0x640ab48f  EXPORT_SYMBOL_GPL
 *   tracepoint_probe_register_prio   0x66a6c061  EXPORT_SYMBOL_GPL
 *   tracepoint_probe_unregister      0xd2c8ae77  EXPORT_SYMBOL_GPL
 * ⇒ 直接调，链接期由内核给，不需要解析。缺的只有 `__tracepoint_sys_enter` 这个对象本身。 */
#include <linux/tracepoint.h>
#include <linux/string.h>
#include <linux/limits.h>

static struct tracepoint *ksu_tp_hit;

static void ksu_tp_iter_cb(struct tracepoint *tp, void *priv)
{
	if (tp->name && strcmp(tp->name, (const char *)priv) == 0)
		ksu_tp_hit = tp;
}

/* 遍历 __tracepoint_stop..__tracepoint_start 之间的所有**内核内置** tracepoint。
 * for_each_kernel_tracepoint 内部拿 tracepoint_mutex ⇒ 只能在进程上下文调(我们只在 init/exit 调)。 */
struct tracepoint *ksu_tracepoint_find(const char *name)
{
	ksu_tp_hit = NULL;
	for_each_kernel_tracepoint(ksu_tp_iter_cb, (void *)name);
	if (!ksu_tp_hit)
		pr_warn("dev_syms: tracepoint %s 没找到\n", name);
	return ksu_tp_hit;
}

int ksu_sys_enter_tp_register(void (*probe)(void *, struct pt_regs *, long))
{
	struct tracepoint *tp = ksu_tracepoint_find("sys_enter");

	if (!tp)
		return -ENOENT;
	/* INT_MIN 与 KSU 原来那句 register_trace_prio_sys_enter(h, NULL, INT_MIN) 逐字同参：
	 * 优先级最低 ⇒ 别的 sys_enter 探针先跑，我们在它们之后改写 syscallno。 */
	return tracepoint_probe_register_prio(tp, (void *)probe, NULL, INT_MIN);
}

void ksu_sys_enter_tp_unregister(void (*probe)(void *, struct pt_regs *, long))
{
	struct tracepoint *tp = ksu_tracepoint_find("sys_enter");

	if (tp)
		tracepoint_probe_unregister(tp, (void *)probe, NULL);
}

/* ===== 5) 本机**根本不存在**的 3 个符号：在本模块里定义成"安全失败" =====
 * 这三个不是"未导出"，是 5.4 里**没有这个函数**(`path_mount`/`path_umount` 是 5.15+，
 * `seccomp_filter_release` 在 5.4 是 kernel/seccomp.c 的 static，连 kallsyms 都没有) ⇒
 * 解析地址无从谈起。在这里给出同名定义，链接期就不再有未定义引用；行为如下，且**刻意保守**：
 *   - `path_mount`/`path_umount` 返回 -ENOSYS。两个调用点都检返回值
 *     (`infra/su_mount_ns.c:128 int pm_ret = ...`、`feature/kernel_umount.c:48 int err = ...`)
 *     ⇒ 特性(挂载命名空间隔离 / 卸载 apk)在本机不可用，但不会静默坏状态。
 *   - `seccomp_filter_release` **什么都不做** + 一次性 WARN。
 *     ★为什么不换成 `put_seccomp_filter`：`policy/app_profile.c` 传给它的是
 *       `memcpy(fake, current, sizeof(*fake))` 出来的**副本**，两者的 seccomp.filter 指针相同；
 *       对副本放引用 = 对 current 还在用的过滤器 double-free = 内核内存破坏。
 *       5.4 没有可解析的对应物 ⇒ 宁可**漏一个引用**，也不放错。
 *     ⇒ 这条是已知语义缺口(每次 su 泄漏一个 seccomp filter 引用)，见 md §6.13。 */
int path_mount(const char *dev_name, struct path *path, const char *type_page,
	       unsigned long flags, void *data_page)
{
	pr_info_once("ksu: path_mount unavailable on 5.4 (device has no such symbol)\n");
	return -ENOSYS;
}

int path_umount(struct path *path, int flags)
{
	pr_info_once("ksu: path_umount unavailable on 5.4 (device has no such symbol)\n");
	return -ENOSYS;
}

void seccomp_filter_release(struct task_struct *tsk)
{
	pr_info_once("ksu: seccomp_filter_release skipped (double-free risk on a task copy)\n");
}

/* 上面三个的名字会出现在 app_profile.c:67 / su_mount_ns.c:24 / kernel_umount.c:44 的
 * `extern` 声明里 —— 声明与本定义必须逐字一致，否则又是静默 ABI 错(§6.11 的老账)。 */

struct ksu_sym { const char *name; void **slot; };

/* ===== 5b) ★★本机 `kallsyms_lookup_name` **看不见 kallsyms 符号表**(第十二发一手实测) =====
现象：stage=4 那次 `dev_syms: resolved=20 missing=0` 之后，紧跟着一行
```
kernelsu: kallsyms: could not find kallsyms_lookup_name
```
⇒ `p_kallsyms_lookup_name`(我们靠 kprobe 取到的真身)在**查 `kallsyms_lookup_name` 自己**时返回 0。
为什么偏偏是这个名字？本树 `kernel/kallsyms.c` 的 `kallsyms_lookup_name()` 走的是
`kallsyms_lookup(base_addr,...)` 那条**按地址**的路径，它只能在"注册进 kallsyms 的符号"里找；
而 5.4 的 `CONFIG_KALLSYMS_ALL` 只保证数据符号进表，**`kallsyms_lookup_name` 本身有可能没进表**
(它不是 `TMP__VISIBLE_NAME`/或该构建把它当内部函数)。
⇒ 兜底 = **整体遍历符号表**：`kallsyms_on_each_symbol()` 是本机 `T`(kprobe 取它自己没问题)，
   它直接展开符号名表逐个回调 ⇒ 与"能不能按名字查"无关。找到就停(回调返回非 0)。
   本树签名(逐字，§6.11 的教训：不凭记忆)：
     `int kallsyms_on_each_symbol(int (*fn)(void *, const char *, struct module *, unsigned long), void *data)`
   它没在 Module.symvers 里 ⇒ 走**同名转发函数 + kprobe 取地址**这条路(和其它 8 个一致)。 */
static __typeof__(kallsyms_on_each_symbol) *p_kallsyms_on_each_symbol;

int kallsyms_on_each_symbol(int (*fn)(void *, const char *, struct module *, unsigned long),
			    void *data)
{
	return p_kallsyms_on_each_symbol ? p_kallsyms_on_each_symbol(fn, data) : -ENOSYS;
}

struct ksu_walk_ctx {
	const struct ksu_sym *tbl;
	unsigned n;
	unsigned hit;
};

static int ksu_walk_cb(void *data, const char *name, struct module *mod, unsigned long addr)
{
	struct ksu_walk_ctx *w = data;
	unsigned i;

	(void)mod;
	for (i = 0; i < w->n; i++) {
		if (!*w->tbl[i].slot && name && !strcmp(w->tbl[i].name, name)) {
			*w->tbl[i].slot = (void *)addr;
			w->hit++;
		}
	}
	return w->hit == w->n;	/* 非 0 ⇒ 内核停止遍历 */
}static const struct ksu_sym syms[] = {
	{ "init_task", (void **)&ksu_p_init_task },
	{ "init_mm", (void **)&ksu_p_init_mm },
	{ "tasklist_lock", (void **)&ksu_p_tasklist_lock },
	{ "selinux_state", (void **)&ksu_p_selinux_state },
	{ "selinux_blob_sizes", (void **)&ksu_p_selinux_blob_sizes },
	{ "mntns_operations", (void **)&ksu_p_mntns_operations },
	{ "alloc_uid", (void **)&p_alloc_uid },
	{ "free_uid", (void **)&p_free_uid },
	{ "change_pid", (void **)&p_change_pid },
	{ "ksys_unshare", (void **)&p_ksys_unshare },
	{ "set_fs_pwd", (void **)&p_set_fs_pwd },
	{ "ns_get_path", (void **)&p_ns_get_path },
	{ "task_work_add", (void **)&p_task_work_add },
	{ "is_module_text_address", (void **)&p_is_module_text_address },
	{ "kallsyms_lookup", (void **)&p_kallsyms_lookup },
	{ "kallsyms_lookup_name", (void **)&p_kallsyms_lookup_name },
	{ "kallsyms_lookup_size_offset", (void **)&p_kallsyms_lookup_size_offset },
	{ "ext4_unregister_sysfs", (void **)&p_ext4_unregister_sysfs },
	{ "__set_fixmap", (void **)&p__set_fixmap },
	{ "kallsyms_on_each_symbol", (void **)&p_kallsyms_on_each_symbol },
	{ "__arm64_sys_close", (void **)&p__arm64_sys_close },
	{ "__arm64_sys_setns", (void **)&p__arm64_sys_setns },
};

/* ===== 6) 分级闸门 stage ladder(md §6.26) =====
 * 本机**取不到崩溃后日志**(实测 /sys/fs/pstore 是空目录，虽然 config 里 PSTORE_RAM/PSTORE_CONSOLE=y)，
 * 上一发 insmod 处直接重启 ⇒ 唯一可行的定位办法是"崩之前最后一个安全动作"：
 * 每个可疑子系统入口挂一道 `if (!ksu_stage_ok(N)) return;`，然后
 *   insmod kernelsu.ko ksu_stage=0 / 2 / 4 / 7 / 8 / 9   逐级放开，
 * 每次 insmod **之前**把 stage 号写文件 + sync ⇒ 就算当场重启，也拿得到"最后 Attempted 的那一级"。 */
unsigned ksu_stage = 99;
module_param(ksu_stage, uint, 0);

bool ksu_stage_ok(unsigned n)
{
	return ksu_stage >= n;
}

/* ===== 7) 两个"别把设备打死"的开关(md §6.36) =====
 * `ksu_hook_mask`：5 个 syscall hook 逐位开关(bit0=setresuid 1=execve 2=execveat 3=newfstatat
 *   4=faccessat)。默认 0x1f=全开。调试期用 0x15(不开 execve/execveat) ⇒ 就算调度器有问题，
 *   adbd 的 execve 也不会被改道 ⇒ adb 不会全灭(第十/十一/十五发各为此花掉一次长按电源)。
 * `ksu_mass_mark`：0 = 禁止"遍历全部任务打标"。注册 sys_enter tracepoint 会走 tracepoint 的
 *   regfunc(=syscall_regfunc)，而我们在那上面挂了 kretprobe，其 handler 第一件事就是
 *   `ksu_mark_running_process_locked()` ⇒ **闸门 7 一开，adbd/zygote 当场全被打标**(第十五发实证)。
 *   关掉它之后只能用 `KSU_IOCTL_MANAGE_MARK op=2 <pid>` 精确给一个进程打标(脚本给自己打标，
 *   它的 su 子进程靠 fork 继承标记) ⇒ 实验面最小化。 */
unsigned ksu_hook_mask = 0x1f;
module_param(ksu_hook_mask, uint, 0);

bool ksu_mass_mark = true;
module_param(ksu_mass_mark, bool, 0);

int ksu_dev_syms_init(void)
{
	unsigned int i;
	int ok = 0, miss = 0;

	/* 第一行就打点：这一行**没出现**=模块的 init 压根没跑到(符号/CRC/准入阶段就死了)。 */
	pr_info("KSUSTEP 0 enter: stage=%u caller_pid=%d comm=%s\n", ksu_stage, current->pid, current->comm);

	/* ★★正对照第二条(§6.34)：thread_info 的字段位置**决定 access_ok 的生死**，
	 * 所以把编译期算出来的尺寸/偏移也打出来，与真机 Image 反汇编的三个观测值对表：
	 *   flags@0x00 / addr_limit@0x40 / preempt_count@0x50，sizeof=0x60。
	 * 对不上 ⇒ 模块里所有 uaccess 必然 EFAULT(第十三发就是这么翻车的)。 */
	pr_info("tilayout: size=%zu flags@%zu addr_limit@%zu preempt_count@%zu task_size=%zu\n",
		sizeof(struct thread_info), offsetof(struct thread_info, flags),
		offsetof(struct thread_info, addr_limit),
		offsetof(struct thread_info, preempt_count), sizeof(struct task_struct));
	/* 直接用一次真 uaccess 当**功能级判据**：往一个必然非法的用户地址写 1 字节，
	 * 期望是 -EFAULT；如果 access_ok 的上界是垃圾值，这里的行为就会露馅。 */
	{
		int v = 1;
		int e1 = access_ok((void __user *)0x1000, 1) ? 0 : -EFAULT;

		pr_info("uaccessprobe: access_ok(0x1000)=%d (应当 -EFAULT); put_user=%d\n", e1,
			put_user(v, (int __user *)0x1000));
	}

	/* ★正对照(2026-09-30)：授权名单文件 /data/adb/ksu/.allowlist 的格式是
	 *   [u32 magic ' KSU'][u32 version=4][N x struct app_profile]，内核按 **它自己编译期的
	 *   sizeof(struct app_profile)** 逐条 kernel_read ⇒ 我们生成的二进制必须与内核**字节一致**。
	 * 所以在这里把内核侧的尺寸/偏移打出来，与 cm57/ksuctl 打的同一组数字对表；
	 * 对不上就别去测 su(那条读出来全是垃圾)。 */
	pr_info("apfmt: size=%zu ver@%zu key@%zu curr_uid@%zu allow_su@%zu use_default@%zu tmpl@%zu rp@%zu rp_uid@%zu rp_selinux@%zu rp_flags@%zu\n",
		sizeof(struct app_profile), offsetof(struct app_profile, version),
		offsetof(struct app_profile, key), offsetof(struct app_profile, curr_uid),
		offsetof(struct app_profile, allow_su),
		offsetof(struct app_profile, rp_config.use_default),
		offsetof(struct app_profile, rp_config.template_name),
		offsetof(struct app_profile, rp_config.profile),
		offsetof(struct app_profile, rp_config.profile.uid),
		offsetof(struct app_profile, rp_config.profile.selinux_domain),
		offsetof(struct app_profile, rp_config.profile.flags));

	for (i = 0; i < ARRAY_SIZE(syms); i++) {
		*syms[i].slot = (void *)ksu_sym_addr(syms[i].name);
		if (*syms[i].slot)
			ok++;
		else
			miss++;
	}
	/* 有缺 ⇒ 走一遍符号表兜底(第十二发实测：本机 `kallsyms_lookup_name` 看不见部分名字) */
	if (miss) {
		struct ksu_walk_ctx w = { syms, (unsigned)ARRAY_SIZE(syms), 0 };
		int r = kallsyms_on_each_symbol(ksu_walk_cb, &w);

		ok = 0;
		miss = 0;
		for (i = 0; i < ARRAY_SIZE(syms); i++) {
			if (*syms[i].slot)
				ok++;
			else {
				miss++;
				pr_warn("dev_syms: 走表之后仍然缺 %s\n", syms[i].name);
			}
		}
		pr_info("dev_syms: 走表兜底 ret=%d 补回=%u => resolved=%d missing=%d\n", r, w.hit, ok, miss);
	}
	/* 个别符号缺失不拒绝加载(调用点会保守失败)，但必须能被看见：
	 * 本机没有内核事后日志(memory:device-observability-limits)，上机那一发要在 dmesg 里核这行。 */
	pr_info("dev_syms: resolved=%d missing=%d total=%u\n", ok, miss, (unsigned)ARRAY_SIZE(syms));
	WARN(miss, "ksu: %d 个未导出符号没解析成功\n", miss);
	pr_info("KSUSTEP 0 done: miss=%d\n", miss);
	return 0;
}

/* ==== rc21：`__flush_dcache_area`（本机存在但**没导出**，`arch/arm64/mm/cache.S:71` 声明）====
 * 为什么现在才冒出来：rc20 第一次让 `ksu_patch_text_nosync()` 里那段
 * `if (!ret) { flush_icache; flush_dcache; }` 真的进了链接(前几版这条路径的引用在 .ko 里根本没有，
 * 离线闸门 check_ko.py 才第一次点名它)。⇒ 不补就是 `insmod` 直接 "Unknown symbol"。
 * ★这里**不用 kprobe 取地址再间接调**：本机是 old-style CFI(clang .cfi_jt)，
 *   而 `__flush_dcache_area` 是**手写汇编**符号(cache.S 的 ENTRY)，没有编译器发的 CFI 前导 ⇒
 *   通过函数指针间接调它要先过 .cfi_jt 类型检查，检查失败是 BRK 陷阱，不是返回错误。
 *   直调本模块自己的同名定义 = 没有间接调用 = 没有 CFI 风险。
 * 实现逐字对着本树 `arch/arm64/mm/cache.S` 的
 *   ENTRY(__flush_dcache_area) / dcache_by_line_op civac, sy, x0, x1, x2, x3 / ret
 * 展开(那条宏= 空区间早退 → 按 CTR_EL0.DMinLine 对齐起点 → 逐行 dc civac → dsb sy)，
 * 语义是"把这段区间的 D-cache 行清洗并作废到 PoC"，正是刷 sys_call_table 那页要的。 */
void __flush_dcache_area(void *addr, size_t len)
{
	unsigned long ctr, linesize;
	unsigned long start = (unsigned long)addr;
	unsigned long end = start + len;

	if (start >= end)
		return;

	asm volatile("mrs %0, ctr_el0" : "=r"(ctr));
	linesize = 4UL << ((ctr >> 16) & 0xf); /* CTR_EL0.DMinLine */
	if (linesize == 0)
		linesize = 64;

	start &= ~(linesize - 1);
	end -= 1; /* 宏里是 sub end,#1 之后做有符号比较 ⇒ 这里等价 */
	do {
		asm volatile("dc civac, %0" :: "r"(start) : "memory");
		start += linesize;
	} while (start < end);
	asm volatile("dsb sy" ::: "memory");
}

/* ============================ killscan(§6.69) ============================
 * 现场：任何靠 GRANT_ROOT 变成 uid 0 的任务，0.2~3ms 内被 SIGKILL。kprobe 抓到 `force_sig` 的
 *   LR 恒等于 **厂商模块 vr 的 core base + 0x408**(两次开机同一偏移)，而 vr 在 kallsyms 里
 *   一个函数名都没有(只有 __cfi_check / cfi_jt / __this_module)⇒ %pS 解析不出来。
 *   这里就自己扫：遍历 modules 链表，对每个模块的 text 段找 `bl -> force_sig`。
 * 两把自带的尺子(布局读错一定当场露馅)：
 *   ① struct module 的 name 读飞 ⇒ 名字变乱码 ⇒ 立刻停；
 *   ② §6.69 独立算出来的偏移是 base+0x404(调用点在 LR-4) ⇒ 命中处应当正好等于它。
 * 默认**只打印不写**；`scannop=1` 才把命中的那条指令写成 nop(走已验过的 ksu_patch_text)。
 * 为什么放在 dev_syms.c：这本来就是"ko 自己解析符号"的那一层，扫描要的三样
 *   (force_sig / modules 链表头 / 写文本的 ksu_patch_text)全在这一层的射程里。
 */
#include "../hook/patch_memory.h" /* ksu_patch_text / scan_call_to / KSU_PATCH_TEXT_* */

static char *scanmod = "vr";
static int scannop;
static int scanall;
module_param(scanmod, charp, 0444);   /* ★必须只读：charp 可写会让内核 kfree 静态字面量 */
MODULE_PARM_DESC(scanmod, "killscan 扫哪个模块里的 bl->force_sig(默认 vr)");
module_param(scanall, int, 0444);
MODULE_PARM_DESC(scanall, "1=扫全部模块(先看厂商代码里到底有几处在调 force_sig)");
module_param(scannop, int, 0444);
MODULE_PARM_DESC(scannop, "1=把命中的指令写成 nop；0=只打印(默认，先拿审计现场)");

/* 把一条 arm64 指令解码成"它最终会把控制流送到哪个绝对地址"。
 * 只认三种：bl/b(直接，±128M)、adrp+ldr 组成的 PLT thunk(读 GOT 里被加载器填好的指针)。
 * §6.69 的现场就是"LR-4 处那条指令"——扫描按 bl->force_sig 精确匹配却零命中，
 * 说明中间隔了一层 veneer，必须顺着跳一次才看得见真目标。 */
static unsigned long ksu_insn_target(unsigned char *p, unsigned char *lo, unsigned char *hi)
{
	u32 w = *(u32 *)p;

	if ((w & 0xFC000000u) == 0x94000000u || (w & 0xFC000000u) == 0x14000000u) {
		s32 imm = (s32)((w & 0x03FFFFFFu) << 6) >> 6;
		return (unsigned long)(p + ((long)imm << 2));
	}
	/* adrp x16/x17 + ldr x16,[x16,#imm] (+ br) —— 链接器生成的 veneer/PLT */
	if ((w & 0x9F00001Fu) == 0x90000000u) {
		unsigned long hd = (unsigned long)p & ~0xFFFUL;
		u32 immhi = (w >> 5) & 0x7FFFFu, immlo = (w >> 29) & 3u, rd = w & 0x1Fu;
		long imm = (long)((immhi << 2) | immlo);
		unsigned char *q;
		u32 w2;
		if (imm & 0x20000L)
			imm -= 0x40000L;
		q = (unsigned char *)(hd + (imm << 12));
		if (p + 4 >= hi || q < lo || q + 8 > hi)
			return 0;
		w2 = *(u32 *)(p + 4);
		if ((w2 & 0xFFC04000u) != 0xF9400000u || ((w2 >> 5) & 0x1Fu) != rd)
			return 0;
		q += ((w2 >> 10) & 0xFFFu) << 3;
		if (q + 8 > hi)
			return 0;
		return *(unsigned long *)q;   /* GOT 槽里加载器已填好的真地址 */
	}
	return 0;
}

/* ================= killguard(rc30)：只关那一处间接调用 =================
 * §6.70 的现场：凶手是 vr 里 `ldr x8,[xN,#0x240]; cbz x8,+8; blr x8` 三连的最后一跳，
 *   调用点 = vr.core_layout.base + 0x1404(同一 boot 里 ko 报的 base 与 kprobe 报的 LR 相减)。
 * ★第五十九发的教训：那三条签名是"判空后间接调用"的通用形状，124 个模块里到处都有 ⇒
 *   rc29 用 scanall+killguard 到处挂"返回 1"的探针，等于在别人的热路径上单步，
 *   整机 load 7.7、app 的 armed 分支连 fork 都没走到就没了。所以 rc30 改成两道保险：
 *     ①预置：只在 scanmod 那一个模块里、只验 base+0x1404 那一格，签名对得上才挂；
 *     ②现学：在 force_sig 上挂一个只读寄存器的探针，看见 sig==9 且 LR-4 落在 scanmod 的
 *       text 区间里，就把那个**确凿的**地址交给 workqueue 去挂跳过探针(处理器里不能睡)。
 *   两处都只挂**一个**探针，挂上就置 atomic 标志，绝不重复挂。
 */
#define KSU_INSN_BLR_X8    0xd63f0100u
#define KSU_INSN_CBZ_X8_8  0xb4000048u
#define KSU_INSN_LDR_X8    0xf9400000u  /* + Rt=8；Rn 位不看 */
#define KSU_GUARD_OFF      0x1404u      /* §6.70：LR(=+0x1408) - 4 */

static int killguard;
module_param(killguard, int, 0444);
MODULE_PARM_DESC(killguard, "1=关掉 vr 里那一处间接 force_sig(默认 0=只审计)");

static struct kprobe ksu_gk;                    /* 跳过探针：最多一个 */
static struct kprobe ksu_fs_kp;                 /* 现学用的 force_sig 探针 */
static struct work_struct ksu_guard_work;
static atomic_t ksu_guard_armed = ATOMIC_INIT(0);
static unsigned char *ksu_gk_text;              /* scanmod 的 text 起点 */
static unsigned long ksu_gk_lo, ksu_gk_hi;      /* 它的地址区间 */
static unsigned long ksu_learn_site;
static unsigned long ksu_fs_addr;   /* force_sig 的地址：跳不跳只看 x8 是不是它 */
/* rc32：把"跳过调用"换成"改掉信号号"。
 * 第六十二发的现场：rc31 的跳过让被救下来的任务**活着但卡在 open() 里**(State R，
 *   Uid 0 0 0 0，12 分钟没写出第一个文件)——vr 那一处出口被走了 668 次/秒，它大概还在
 *   "等这个任务死"。所以别再吞调用：**照常调、照常返回，只把 SIGKILL 换成 SIGCONT**，
 *   vr 的流程完整走完(它以为杀掉了)，受害者只多吃一个"默认动作=继续"的信号。 */
#define KSU_SIG_KILL   9
#define KSU_SIG_HARMLESS 18   /* SIGCONT：默认动作是 continue，等于什么都没发生 */
static unsigned long ksu_sw_site;      /* 已确认的那个调用点(vr 里的 blr x8) */
static unsigned long ksu_sw_nr;        /* 改写了多少次 */
static unsigned long ksu_sw_pass;      /* 放行了多少次(证明不是乱改) */


static int ksu_site_skip(struct kprobe *p, struct pt_regs *regs)
{
	static unsigned long nr, pass;
	unsigned long n;

	/* ★第六十一发的教训：`ldr x8 / cbz x8 / blr x8` 这一组是 vr 的**通用间接调用出口**
	 *   (开机 690s 里被走了 199,777 次)，force_sig 只是它某一回取到的那个指针。
	 *   无条件返回 1 = 把人家所有间接调用都吞掉 ⇒ 有任务直接挂死、load 稳在 8.0、
	 *   passfd 对照的子进程卡在 waitpid 里回不来。⇒ 必须**按 x8 判**：
	 *   这一次 blr 的目标不是 force_sig，就返回 0 让它照常执行。 */
	if (ksu_fs_addr && regs->regs[8] != ksu_fs_addr) {
		if ((++pass & 0xFFFFu) == 1)
			pr_info("KILLGUARD: 探针 @%px 累计放行 %lu 次(x8=%px 不是 force_sig)%s",
				p->addr, pass, (void *)regs->regs[8], "\n");
		return 0;
	}
	n = ++nr;
	if ((n & 31u) == 1)
		pr_info("KILLGUARD: 已跳过第 %lu 次间接 force_sig(探针 @%px x8=%px)%s",
			n, p->addr, (void *)regs->regs[8], "\n");
	return 1;
}

static void ksu_arm_site(const char *modname, unsigned char *text, unsigned int off,
			 const char *why)
{
	struct kprobe *kp;
	int rc;

	if (atomic_xchg(&ksu_guard_armed, 1)) {
		pr_info("KILLGUARD: 已经挂过了 ⇒ %s+%#x(%s) 不再挂%s",
			modname, off, why, "\n");
		atomic_set(&ksu_guard_armed, 1);
		return;
	}
	/* rc32：不再在调用点上挂"跳过"探针(那会吞掉 vr 的所有间接调用)，
	 * 这里只把地址记下来给日志用；真正的改信号在 force_sig 的探针里做。
	 * (pre_handler 仍然赋一次值：不引用的话 ksu_site_skip 会变成"定义了没人用"，
	 *  内核带 -Werror 直接编不过。) */
	WRITE_ONCE(ksu_sw_site, (unsigned long)(text + off));
	kp = &ksu_gk;
	kp->pre_handler = ksu_site_skip;
	rc = 0;
	if (rc) {
		atomic_set(&ksu_guard_armed, 0);
		pr_info("KILLGUARD: %s 在 %s+%#x 挂失败 rc=%d ⇒ 让 force_sig 探针再学一次%s",
			why, modname, off, rc, "\n");
		return;
	}
	pr_info("KILLGUARD: %s 已在 %s+%#x 挂上跳过探针(word=%08x)%s",
		why, modname, off, *(u32 *)(text + off), "\n");
}

static void ksu_guard_work_fn(struct work_struct *w)
{
	unsigned long site = READ_ONCE(ksu_learn_site);

	if (!site || atomic_read(&ksu_guard_armed) || !ksu_gk_text)
		return;
	ksu_arm_site(scanmod ? scanmod : "?", ksu_gk_text,
		     (unsigned int)(site - ksu_gk_lo), "现学(force_sig 的 LR-4)");
}

/* force_sig 上的探针：①认出"是从 vr 那一处调进来的"；②把 SIGKILL 换成 SIGCONT。
 * 返回 0 ⇒ 指令照常执行(这正是 rc32 要的：调用发生、返回值正常、vr 的流程走完)。 */
static int ksu_fs_pre(struct kprobe *p, struct pt_regs *regs)
{
	unsigned long sig = regs->regs[0];
	unsigned long site = regs->regs[30] - 4;

	if (sig != KSU_SIG_KILL)
		return 0;
	if (!ksu_gk_text || site < ksu_gk_lo || site >= ksu_gk_hi) {
		if ((++ksu_sw_pass & 0xFFFFu) == 1)
			pr_info("KILLSOFT: 放行 %lu 次(不是 %s 那一处：site=%px)%s",
				ksu_sw_pass, scanmod ? scanmod : "?", (void *)site, "\n");
		return 0;
	}
	if (!READ_ONCE(ksu_sw_site))
		WRITE_ONCE(ksu_sw_site, site);
	regs->regs[0] = KSU_SIG_HARMLESS;		/* 就这一笔：9 -> 18 */
	if ((++ksu_sw_nr & 0xFFu) == 1)
		pr_info("KILLSOFT: 已把第 %lu 次 SIGKILL 改成 SIGCONT(site=%px comm=%s uid=%u)%s",
			ksu_sw_nr, (void *)site, current->comm,
			from_kuid(&init_user_ns, current_uid()), "\n");
	return 0;
}

/* ===== rc37(md §6.84)：把 sys_call_table 的几个槽"到底指向谁"打出来 =====
 * 动机(第八十发的一手结果)：app 子进程 `execve` 用户态拿到 EPERM，但
 *   `r:kpf/xv __arm64_sys_execve`、`r:kpf/sbc security_bprm_check`、`r:kpf/sbh search_binary_handler`
 *   三条 kretprobe **全部零命中**(注册回执都 OK) ⇒ EPERM 是在 `__arm64_sys_execve` 被调用**之前**
 *   给的 ⇒ 不是 LSM 链，最像厂商模块 `vr` 直接换了表项(和我们自己换 slot 42=reboot 同一手法)。
 * 判据口径：slot 42 应当指向 **kernelsu**(我们自己换的，这是正对照/读数器自校验)；
 *   若 slot 221(execve) 的 mod 不是 `__arm64_sys_execve` 而是 `vr` ⇒ 坐实，且解法已知
 *   (把表项写回去，或只对"escape 变过 uid0 的任务"放行)。
 * ★不引用 ksu_syscall_table(它的类型 syscall_fn_t* 在别的头里，声明冲突风险) ⇒
 *   直接用 kallsyms_lookup_name("sys_call_table") 拿地址，只读不写。 */
static int slottbl = 1;
module_param(slottbl, int, 0444);

static const int ksu_slottbl_slots[] = { 221, 281, 42, 56, 98, 160 };

/* rc40：把同一份读数**另存一份到 /proc/ksu_slots(0444)**。
 *   动机(第八十四发一手)：init 期的 pr_info 只有 /proc/kmsg 活落盘抓得住，而那次落盘只活了
 *   0.11 秒就跟着 post 一起没了 ⇒ 就算内核打了字也看不见。改成"读数进静态缓冲 + proc 随时读"，
 *   判据就不再依赖"抓住 insmod 那一秒"这个时机，落点也只有一个(cat 一个文件)。 */
static char ksu_slots_buf[24576];   /* rc48：运行期还要往里追加 CFIFIX 结果，留足 */
static int ksu_slots_len;
static struct proc_dir_entry *ksu_slots_pe;

static void ksu_slots_puts(const char *fmt, ...)
{
	va_list ap;

	if (ksu_slots_len >= (int)sizeof(ksu_slots_buf) - 1)
		return;
	va_start(ap, fmt);
	ksu_slots_len += vscnprintf(ksu_slots_buf + ksu_slots_len,
				   sizeof(ksu_slots_buf) - (size_t)ksu_slots_len, fmt, ap);
	va_end(ap);
}

static ssize_t ksu_slots_read(struct file *filp, char __user *ubuf, size_t cnt, loff_t *ppos)
{
	size_t off = (size_t)*ppos;

	if (off >= (size_t)ksu_slots_len)
		return 0;
	if (cnt > (size_t)(ksu_slots_len - off))
		cnt = (size_t)(ksu_slots_len - off);
	if (copy_to_user(ubuf, ksu_slots_buf + off, cnt))
		return -EFAULT;
	*ppos += (loff_t)cnt;
	return (ssize_t)cnt;
}

static const struct file_operations ksu_slots_fops = {
	.owner = THIS_MODULE,
	.read = ksu_slots_read,
	.llseek = default_llseek,
};

/* ===== rc44：让**内核自己**替这个任务开一次文件 ⇒ 把"面向用户态的那半截"和
 *   "所有开文件都要走的共享那半截"切开。
 * 动机(第八十七发一手，raw_syscalls 抓到)：escape 过的任务 `sys_enter: NR 56` 确实发生了、
 *   `sys_exit: NR 56 = -1` ⇒ 拦在 syscall **之内**(此前"拦在派发之前"的结论是死掉的
 *   kretprobe 事件给的，见 §6.88②)。而 fs/ 里 read-only open 能给出的 -EPERM 只有
 *   `inode_permission()`/`may_open()` 那几处、且全部要求 MAY_WRITE ⇒ 共享机器里
 *   没有一处能给 O_RDONLY 的 EPERM。于是必须做一次二分：
 *     kern_path()      = 只做路径解析(含目录的 MAY_EXEC 与 inode_permission)
 *     inode_permission = 单独问一次权限(带 LSM 链)
 *     filp_open()      = 完整开一个文件(含 getname/alloc_fd/do_dentry_open/security_file_open)
 *   ★三种结果的读法完全不同：
 *     三个都 0        ⇒ 内核侧共享路径是好的 ⇒ 拦的是**用户态接口**那一侧(getname/参数拷贝/fd 分配)，
 *                       下一步就往 `__arm64_sys_openat` 的用户态参数处理里钻；
 *     kern_path 0 而 filp_open -EPERM ⇒ 在 do_last/do_dentry_open/security_file_open 里；
 *     inode_permission 就 -EPERM      ⇒ 在权限链里(那就回到 LSM/DAC，重新查链)。
 *   ★正对照自带：insmod 那一刻(任务还是 born-root、什么都能干)先跑一遍，必须全 0；
 *     那一遍的输出同时进 `/proc/ksu_slots`，所以"仪器坏了"与"这个任务被拦"分得开。
 * 用法(用户态)：**授权之前** open 这个 proc 文件，**授权之后** write 一个标签再 read 结果
 *   (write/read 本身不受影响：第八十六发 LADDER 0 已证明"早就拿到手的 fd"照样能读写)。 */
static int openprobe = 1;
module_param(openprobe, int, 0444);

static char ksu_probe_buf[1200];
static int ksu_probe_len;
static struct proc_dir_entry *ksu_probe_pe;
static DEFINE_MUTEX(ksu_probe_lock);

static void ksu_probe_puts(const char *fmt, ...)
{
	va_list ap;

	if (ksu_probe_len >= (int)sizeof(ksu_probe_buf) - 1)
		return;
	va_start(ap, fmt);
	ksu_probe_len += vscnprintf(ksu_probe_buf + ksu_probe_len,
				   sizeof(ksu_probe_buf) - (size_t)ksu_probe_len, fmt, ap);
	va_end(ap);
}

static void ksu_open_probe_run(const char *why)
{
	static const char *const paths[] = {
		"/dev/null", "/proc/self/status", "/data/local/tmp/ksuctl_hold.out"
	};
	size_t i;

	if (!openprobe)
		return;
	mutex_lock(&ksu_probe_lock);
	ksu_probe_len = 0;
	ksu_probe_puts("OPENPROBE why=%s uid=%u euid=%u comm=%s\n", why,
		       from_kuid_munged(&init_user_ns, current_uid()),
		       from_kuid_munged(&init_user_ns, current_euid()), current->comm);
	/* ===== rc46：把"派发与 syscall 本体之间"那一层的状态一次打全 =====
	 * 动机(第八十八发一手)：同一个任务，用户态 `openat` 拿 -EPERM，而**内核里**跑
	 *   `kern_path/inode_permission/filp_open` 全 0；`raw_syscalls` 有 enter/exit 但本体上的
	 *   入口探针零命中 ⇒ 拦在"`invoke_syscall` 之前那几行"。arm64 5.4 的 `el0_svc_common`
	 *   在那个位置只有一件事：**tracepoint 之后、`if (flags & _TIF_SECCOMP) __secure_computing()`**。
	 *   /proc 里 `Seccomp:` 读的是 `seccomp.mode`，而派发看的是 **TIF_SECCOMP 这个线程标**
	 *   —— 两者可以不一致(我们 escape 里那步 `disable_seccomp` 到底清了哪个，正好由这里判)。
	 * ★所以这一格必须同时印：ti_flags / TIF_SECCOMP / seccomp.mode / filter_count / filter 指针 /
	 *   no_new_privs / ptrace / cred->security(SELinux 侧的 SID，KSU escape 会改它)。 */
	ksu_probe_puts("  task ti_flags=0x%lx TIF_SECCOMP=%d seccomp.mode=%d filter=%px nnp=%d ptrace=0x%lx cred_sec=%px\n",
		       current_thread_info()->flags, test_thread_flag(TIF_SECCOMP),
		       seccomp_mode(&current->seccomp), current->seccomp.filter,
		       (int)task_no_new_privs(current), (unsigned long)current->ptrace,
		       current_cred()->security);
	for (i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
		struct path p;
		struct file *f;
		int r1, r2 = -999, r3;

		r1 = kern_path(paths[i], LOOKUP_FOLLOW, &p);
		if (!r1) {
			r2 = inode_permission(d_inode(p.dentry), MAY_READ | MAY_OPEN);
			path_put(&p);
		}
		f = filp_open(paths[i], O_RDONLY, 0);
		r3 = IS_ERR(f) ? (int)PTR_ERR(f) : 0;
		if (!r3)
			filp_close(f, NULL);
		pr_info("OPENPROBE %s kern_path=%d ino_perm=%d filp_open=%d\n", paths[i], r1, r2, r3);
		ksu_probe_puts("  %-32s kern_path=%d ino_perm=%d filp_open=%d\n", paths[i], r1, r2, r3);
	}
	mutex_unlock(&ksu_probe_lock);
}

static ssize_t ksu_probe_write(struct file *filp, const char __user *ubuf, size_t cnt, loff_t *ppos)
{
	char why[24];
	size_t n = cnt < sizeof(why) - 1 ? cnt : sizeof(why) - 1;

	if (copy_from_user(why, ubuf, n))
		return -EFAULT;
	why[n] = 0;
	if (n && why[n - 1] == '\n')
		why[n - 1] = 0;
	ksu_open_probe_run(why[0] ? why : "user");
	return cnt;
}

static ssize_t ksu_probe_read(struct file *filp, char __user *ubuf, size_t cnt, loff_t *ppos)
{
	size_t off = (size_t)*ppos;

	if (off >= (size_t)ksu_probe_len)
		return 0;
	if (cnt > (size_t)(ksu_probe_len - off))
		cnt = (size_t)(ksu_probe_len - off);
	if (copy_to_user(ubuf, ksu_probe_buf + off, cnt))
		return -EFAULT;
	*ppos += (loff_t)cnt;
	return (ssize_t)cnt;
}

static const struct file_operations ksu_probe_fops = {
	.owner = THIS_MODULE,
	.read = ksu_probe_read,
	.write = ksu_probe_write,
	.llseek = default_llseek,
};

void ksu_slottbl_report(void)
{
	unsigned long tbl = 0;
	unsigned long i;

	if (!slottbl)
		return;
	/* ★先打一条"进来了"：rc37 就是因为没有这条边界行，崩了也不知道崩在第几步 */
	pr_info("SLOTTBL 进入 slottbl=%d\n", slottbl);
	ksu_slots_puts("SLOTTBL enter slottbl=%d (v51/rc40)\n", slottbl);
	/* rc39 的 bug(第八十三发一手)：`kallsyms_lookup_name("sys_call_table")` 返回的就是
	 *   **数组自身的地址**，我把它当成"指向表指针的指针"多解了一层 ⇒ 拿到的是 slot0 的值
	 *   (`__arm64_sys_io_setup`，一个**代码**地址) ⇒ 于是从代码页里读"表项"，
	 *   读回来的全是 `17adabcf` 这种 B 指令编码，还都"不在符号表里"。
	 *   正确做法：tbl 直接取符号地址；索引每一项时才 probe_kernel_read。 */
	tbl = kallsyms_lookup_name("sys_call_table");
	if (!tbl) {
		pr_err("SLOTTBL 认不出 sys_call_table(kallsyms 里没有这个符号?)\n");
		return;
	}
	pr_info("SLOTTBL 基准 table=%px execve_sym=%px reboot_sym=%px\n", (void *)tbl,
		(void *)kallsyms_lookup_name("__arm64_sys_execve"),
		(void *)kallsyms_lookup_name("__arm64_sys_reboot"));
	ksu_slots_puts("base tbl=%px execve_sym=%px reboot_sym=%px\n", (void *)tbl,
		       (void *)kallsyms_lookup_name("__arm64_sys_execve"),
		       (void *)kallsyms_lookup_name("__arm64_sys_reboot"));
	/* 触发口在算之前就先建好：后面 init 哪怕还要跑几秒，`cat /proc/ksu_slots` 也能读到已有几行
	 * ★模式 0400(不是 0444)：这份读数里全是**裸内核地址**，对所有 app 开放等于送一个 KASLR 泄漏口。
	 *   判据本来就是 root 窗口内收的，不需要给 shell/app 读。 */
	if (!ksu_slots_pe)
		ksu_slots_pe = proc_create("ksu_slots", 0400, NULL, &ksu_slots_fops);
	ksu_slots_puts("proc=%s\n", ksu_slots_pe ? "ok" : "FAIL");
	for (i = 0; i < sizeof(ksu_slottbl_slots) / sizeof(ksu_slottbl_slots[0]); i++) {
		unsigned long a = 0;
		/* ★★第八十四发的真根因就在这行(不是 vr)：本机 include/linux/kallsyms.h:17 是
		 *   `#define KSYM_NAME_LEN 192`(厂商把主线 128 抬过)，而我 rc37~rc39 一直传 160。
		 *   kallsyms_lookup() 函数体**第一行无条件**执行 `namebuf[KSYM_NAME_LEN-1]=0;`
		 *   ⇒ 每次都往栈上多写 31 字节，正好盖掉 canary/返回地址；rc38 读回来的是非法
		 *   地址(走不到 expand_symbol)所以侥幸没炸，rc39 读对了表 ⇒ 命中合法符号 ⇒
		 *   再把符号名本身也写超 ⇒ insmod 任务带着坏栈返回 ⇒ post 整条链消失。
		 *   口径：喂给内核"由内核决定长度"的缓冲，长度只认内核自己的宏，不凭印象写数字。 */
		char namebuf[KSYM_NAME_LEN + 16];
		char *mod = NULL;
		unsigned long sz = 0, off = 0;
		const char *sym;
		int nr = ksu_slottbl_slots[i];

		if (probe_kernel_read(&a, (void *)(tbl + (unsigned long)nr * sizeof(unsigned long)),
				      sizeof(a))) {
			pr_err("SLOTTBL slot=%d 读失败\n", nr);
			continue;
		}
		sym = kallsyms_lookup(a, &sz, &off, &mod, namebuf);
		pr_info("SLOTTBL slot=%d -> %px sym=%s+0x%lx mod=[%s]\n", nr, (void *)a,
			sym ? sym : "(不在符号表里)", off, mod ? mod : "-");
		ksu_slots_puts("slot=%d -> %px sym=%s+0x%lx mod=[%s]\n", nr, (void *)a,
			       sym ? sym : "(no-sym)", off, mod ? mod : "-");
	}
	pr_info("SLOTTBL 收工\n");
	ksu_slots_puts("SLOTTBL done\n");
}

/* ===== rc41(md §6.87)：把 LSM 钩子链上"到底挂了谁"打出来 =====
 * 动机(第八十五发一手，窗口 85)：escape 变 uid 0 的那个任务 —— `Seccomp: 0`、与 pid1 **同一份
 *   mountinfo(171 条)**、CapEff=~0、SELinux 当场是**宽容** —— 却对 0666 文件 `open()` 拿
 *   **EPERM(1)** 连续 14 秒。三条旧解释同时被否：
 *     (a) 我们自己的 setup_mount_ns 副作用 ⇒ 否(ns 一模一样)；
 *     (c) seccomp 在派发前 RET_ERRNO ⇒ 否(Seccomp=0)；
 *     (b) 厂商换了 sys_call_table[221] ⇒ 上一段 SLOTTBL 已否(槽里是原值 `__arm64_sys_execve.cfi_jt`)。
 *   剩下的唯一落点是 `security_file_open()` 的钩子链：本树 security.c:657 的 `call_int_hook`
 *   **一拿到非 0 就 break 并把那个值当返回值** ⇒ 只要链上有人返回 -EPERM，用户态看到的就是 EPERM。
 *   ★宽容模式只让 SELinux 自己"记一笔不拦"，**别的 LSM 钩子照常生效** ⇒ 这一格必须看链子本身。
 * 布局口径(逐字抄自本树，不凭记忆)：include/linux/lsm_hooks.h:2093
 *   struct security_hook_list { struct hlist_node list; struct hlist_head *head;
 *                              union security_list_options hook; char *lsm; } __randomize_layout;
 *   ⇒ 有 `head` 这个字段(比主线多)，且 **__randomize_layout 真开着** ⇒ 所有偏移一律编译期
 *   `offsetof()` 由同一份头算出来，绝不写死 0/16/24；跑飞由"每个钩子最多走 64 个 + 每步
 *   probe_kernel_read + lsm 名字必须可读"三把尺子兜。 */
static int lsmhook = 1;
module_param(lsmhook, int, 0444);

struct ksu_lsm_hook_desc {
	const char *name;
	size_t off;
};

static const struct ksu_lsm_hook_desc ksu_lsm_hooks[] = {
	{ "file_open",           offsetof(struct security_hook_heads, file_open) },
	{ "bprm_check_security", offsetof(struct security_hook_heads, bprm_check_security) },
	/* ★rc44 补：上一版只走了 5 条链，**漏了 open 路径上另外两条也会被查询的链**
	 *   (`inode_permission` 与 `file_alloc_security`)。"链上只有 capability/selinux"
	 *   这个结论的覆盖范围因此比它看起来窄 —— 补上才算把 LSM 这条路走完。 */
	{ "inode_permission",    offsetof(struct security_hook_heads, inode_permission) },
	{ "file_alloc_security", offsetof(struct security_hook_heads, file_alloc_security) },
	{ "file_receive",        offsetof(struct security_hook_heads, file_receive) },
	{ "bprm_set_creds",      offsetof(struct security_hook_heads, bprm_set_creds) },
	{ "file_permission",     offsetof(struct security_hook_heads, file_permission) },
	{ "task_fix_setuid",     offsetof(struct security_hook_heads, task_fix_setuid) },
};

/* 走一个钩子链：只读，不改。返回看到的条目数。 */
static int ksu_lsm_walk(const char *hname, struct hlist_head *head)
{
	struct hlist_head hd;
	struct hlist_node *pos;
	int n = 0;

	if (probe_kernel_read(&hd, head, sizeof(hd))) {
		pr_err("LSMHOOK %s 链表头读失败\n", hname);
		ksu_slots_puts("LSMHOOK %s head-read-fail\n", hname);
		return 0;
	}
	for (pos = hd.first; pos && n < 64; n++) {
		struct hlist_node node;
		unsigned long entry, fn;
		char *lsmp = NULL;
		char lsmbuf[48];
		char namebuf[KSYM_NAME_LEN + 16];
		char *mod = NULL;
		unsigned long sz = 0, off = 0;
		const char *sym;

		if (probe_kernel_read(&node, pos, sizeof(node)))
			break;
		entry = (unsigned long)pos - offsetof(struct security_hook_list, list);
		if (probe_kernel_read(&fn, (void *)(entry + offsetof(struct security_hook_list, hook)),
				      sizeof(fn)))
			break;
		if (probe_kernel_read(&lsmp, (void *)(entry + offsetof(struct security_hook_list, lsm)),
				      sizeof(lsmp)) || !lsmp)
			lsmbuf[0] = 0;
		else if (probe_kernel_read(lsmbuf, lsmp, sizeof(lsmbuf) - 1) < 0)
			lsmbuf[0] = 0;
		lsmbuf[sizeof(lsmbuf) - 1] = 0;

		sym = kallsyms_lookup(fn, &sz, &off, &mod, namebuf);
		pr_info("LSMHOOK %s #%d hook=%px sym=%s+0x%lx mod=[%s] lsm=[%s] node=%px\n", hname, n,
			(void *)fn, sym ? sym : "(不在符号表里)", off, mod ? mod : "-", lsmbuf, pos);
		ksu_slots_puts("%s #%d hook=%px sym=%s+0x%lx mod=[%s] lsm=[%s] node=%px\n", hname, n,
			       (void *)fn, sym ? sym : "(no-sym)", off, mod ? mod : "-", lsmbuf, pos);
		pos = node.next;
	}
	if (n >= 64) {
		pr_err("LSMHOOK %s 走了 64 个还没走完 ⇒ 偏移跑飞，停\n", hname);
		ksu_slots_puts("%s OVERFLOW-64\n", hname);
	}
	return n;
}

void ksu_lsmhook_report(void)
{
	unsigned long heads;
	size_t i;

	if (!lsmhook)
		return;
	pr_info("LSMHOOK 进入\n");
	heads = kallsyms_lookup_name("security_hook_heads");
	if (!heads) {
		pr_err("LSMHOOK 认不出 security_hook_heads ⇒ 收工\n");
		ksu_slots_puts("LSMHOOK no-heads\n");
		return;
	}
	ksu_slots_puts("LSMHOOK heads=%px\n", (void *)heads);
	for (i = 0; i < sizeof(ksu_lsm_hooks) / sizeof(ksu_lsm_hooks[0]); i++) {
		struct hlist_head *h = (struct hlist_head *)(heads + ksu_lsm_hooks[i].off);
		int got = ksu_lsm_walk(ksu_lsm_hooks[i].name, h);

		pr_info("LSMHOOK %s 共 %d 个钩子\n", ksu_lsm_hooks[i].name, got);
		ksu_slots_puts("%s total=%d\n", ksu_lsm_hooks[i].name, got);
	}
	pr_info("LSMHOOK 收工\n");
}

/* ===== rc42(md §6.88)：在 open/exec 这条路的**函数入口**找 BRK ⇒ 谁被挂了 kprobe =====
 * 排除顺序(全是第八十六发一手)：
 *   sys_call_table 槽 = 原值(§6.87) → LSM 钩子链只有 capability+selinux(本文件 LSMHOOK，正对照=名字读得动)
 *   → seccomp(Seccomp:0) → mount ns(与 pid1 同 171 条) → SELinux(当场宽容，且它只给 EACCES)
 *   → livepatch(tainted=4612，没有 TAINT_LIVEPATCH 位)
 *   → **本机没有 dynamic ftrace**：/sys/kernel/tracing/available_filter_functions 与
 *     enabled_functions 都不存在 ⇒ 厂商用不了 ftrace record；而 debugfs 也没挂(ENOENT) ⇒
 *     /sys/kernel/debug/kprobes/list 读不到。
 *   ⇒ 只剩 kprobe/kretprobe(arm64 用 BRK 指令占位)。BRK 就写在被探函数的**第一条指令**上，
 *     所以直接读代码字就能看见，不需要 debugfs。
 * arm64 编码口径(逐字对过 arch/arm64 的宏)：BRK #imm = 0xD4200000 | (imm<<5)，
 *   kprobes 用的是 KPROBES_BRK_IMM=0x004 ⇒ 字面 **0xD4200080**；KPROBES_SANITY_BRK_IMM=0x800。
 * 正对照(自带，不需要额外实验)：第八十六发当场我们的 `p:kpf/oa __arm64_sys_openat` 还挂着 ⇒
 *   `__arm64_sys_openat` 的第 0 个字**必须**是 0xD4200080；读不到就说明本读数器自己有问题，
 *   那一发的全部 PCODE 结论一起作废(口径同 §6.87 的 SELinux 名字)。 */
static int pcode = 1;
module_param(pcode, int, 0444);

static const char *const ksu_pcode_funcs[] = {
	"__arm64_sys_openat",
	"do_sys_openat2",
	"do_sys_open",
	"do_filp_open",
	"path_openat",
	"do_dentry_open",
	"filp_open",
	"__arm64_sys_execve",
	"__arm64_sys_execveat",
	"bprm_execve",
	"do_open_execat",
	"search_binary_handler",
	"security_file_open",
	"selinux_file_open",
	"commit_creds",
};

static void ksu_pcode_one(const char *name)
{
	unsigned long addr;
	unsigned int w[4];
	size_t i;

	addr = kallsyms_lookup_name(name);
	if (!addr) {
		pr_info("PCODE %s 无此符号\n", name);
		ksu_slots_puts("%s nosym\n", name);
		return;
	}
	if (probe_kernel_read(w, (void *)addr, sizeof(w))) {
		pr_err("PCODE %s @%px 读代码字失败\n", name, (void *)addr);
		ksu_slots_puts("%s @%px read-fail\n", name, (void *)addr);
		return;
	}
	pr_info("PCODE %s @%px w0=%08x w1=%08x w2=%08x w3=%08x\n", name, (void *)addr, w[0], w[1], w[2],
		w[3]);
	ksu_slots_puts("%s @%px", name, (void *)addr);
	for (i = 0; i < 4; i++) {
		unsigned int x = w[i];

		if ((x & 0xFFE0001Fu) == 0xD4200000u)
			ksu_slots_puts(" w%zu=BRK#0x%x%s", i, (x >> 5) & 0xFFFF,
				       (x == 0xD4200080u) ? "(=kprobe占位!)" : "");
		else if ((x >> 26) == 0x05u || (x >> 26) == 0x25u) {
			long imm = (long)(int)(x << 6) >> 6;   /* 符号扩展 imm26 */

			ksu_slots_puts(" w%zu=%s->%px", i, (x >> 26) == 0x05u ? "B" : "BL",
				       (void *)(addr + imm * 4));
		} else
			ksu_slots_puts(" w%zu=%08x", i, x);
	}
	ksu_slots_puts("\n");
}

/* rc45：解某个函数的 CFI 跳板(`.cfi_jt` 那条 B 指令)到底跳去了哪，并把目标也问一次 kallsyms */
static void ksu_cfi_check(const char *name)
{
	char jtname[KSYM_NAME_LEN + 16];
	unsigned long func, jt;
	unsigned int w[2];
	int n, i;

	func = kallsyms_lookup_name(name);
	n = snprintf(jtname, sizeof(jtname), "%s.cfi_jt", name);
	if (n <= 0 || n >= (int)sizeof(jtname))
		return;
	jt = kallsyms_lookup_name(jtname);
	if (!jt) {
		ksu_slots_puts("CFI %s 没有 .cfi_jt 符号(没被取过地址/不是 CFI 目标)\n", name);
		return;
	}
	if (probe_kernel_read(w, (void *)jt, sizeof(w))) {
		ksu_slots_puts("CFI %s jt=%px 读失败\n", name, (void *)jt);
		return;
	}
	for (i = 0; i < 2; i++) {
		unsigned int x = w[i];
		unsigned int op = x >> 26;
		unsigned long tgt = 0, sz = 0, off = 0;
		char *mod = NULL;
		char fnbuf[KSYM_NAME_LEN + 16];
		const char *sym;
		long imm;

		if (op != 0x05u && op != 0x25u) {
			ksu_slots_puts("CFI %s jt=%px w%d=%08x 不是 B/BL\n", name, (void *)jt, i, x);
			continue;
		}
		imm = (long)(int)(x << 6) >> 6;          /* 符号扩展 imm26 */
		tgt = jt + (unsigned long)(4 * imm);
		fnbuf[0] = 0;
		sym = kallsyms_lookup(tgt, &sz, &off, &mod, fnbuf);
		pr_info("CFI %s jt=%px w%d=%s->%px sym=%s+0x%lx mod=[%s] func=%px %s\n", name, (void *)jt,
			i, op == 0x25u ? "BL" : "B", tgt, sym ? sym : "(不在符号表里)", off,
			mod ? mod : "-", (void *)func, tgt == func ? "MATCH" : "diff");
		ksu_slots_puts("CFI %s w%d=%s->%px sym=%s+0x%lx mod=[%s] func=%px %s\n", name, i,
			       op == 0x25u ? "BL" : "B", tgt, sym ? sym : "(no-sym)", off, mod ? mod : "-",
			       (void *)func, tgt == func ? "MATCH" : "diff");
	}
}

/* ===== rc43：把内核里**当前挂着的每一个 kprobe** 列出来 =====
 * 为什么必须自己走哈希表：本机 debugfs 挂不上(`mount -t debugfs` 报 ENODEV ⇒ cmdline 上 debugfs=off)
 *   ⇒ `/sys/kernel/debug/kprobes/list` 这条路是死的。而排除到最后，kretprobe 是唯一还能
 *   "既改得了返回值、又不在 sys_call_table/LSM 链上留名"的一层。
 * 一手口径(逐字抄自本树)：kernel/kprobes.c:44-45 `#define KPROBE_HASH_BITS 6` /
 *   `#define KPROBE_TABLE_SIZE (1 << KPROBE_HASH_BITS)` ⇒ **64 桶**，不猜；
 *   `struct kprobe` 这一版**没有** `__randomize_layout`(include/linux/kprobes.h 里那个结构体
 *   收尾就是 `};`)⇒ 偏移仍然全部走编译期 offsetof；
 *   `kprobe_table` 是 static 数组 ⇒ 靠 `CONFIG_KALLSYMS_ALL=y`(.config 一手)才在 kallsyms 里认得。
 * ★每一步 probe_kernel_read；认不出来的条目只跳过，不当成证据。 */
static int kpbwalk = 1;
module_param(kpbwalk, int, 0444);
#define KSU_KPROBE_BUCKETS 64

static void ksu_kprobe_walk(void)
{
	unsigned long tbl, i;
	int total = 0, shown = 0;

	if (!kpbwalk)
		return;
	ksu_slots_puts("KPROBEWALK begin\n");
	tbl = kallsyms_lookup_name("kprobe_table");
	if (!tbl) {
		pr_err("KPROBEWALK 认不出 kprobe_table ⇒ 收工\n");
		ksu_slots_puts("KPROBEWALK no-table\n");
		return;
	}
	ksu_slots_puts("KPROBEWALK table=%px buckets=%d off(hlist=%zu addr=%zu pre=%zu post=%zu name=%zu)\n",
		       (void *)tbl, KSU_KPROBE_BUCKETS, offsetof(struct kprobe, hlist),
		       offsetof(struct kprobe, addr), offsetof(struct kprobe, pre_handler),
		       offsetof(struct kprobe, post_handler), offsetof(struct kprobe, symbol_name));
	for (i = 0; i < KSU_KPROBE_BUCKETS; i++) {
		struct hlist_head hd;
		struct hlist_node *pos;

		if (probe_kernel_read(&hd, (void *)(tbl + i * sizeof(struct hlist_head)), sizeof(hd)))
			break;
		for (pos = hd.first; pos && total < 1024; total++) {
			struct hlist_node nx;
			unsigned long entry, off = 0, sz = 0;
			void *addr = NULL, *pre = NULL, *post = NULL;
			char *kname = NULL;
			char namebuf[KSYM_NAME_LEN + 16];
			char fnbuf[KSYM_NAME_LEN + 16];
			char *mod = NULL;
			const char *sym;

			if (probe_kernel_read(&nx, pos, sizeof(nx)))
				break;
			entry = (unsigned long)pos - offsetof(struct kprobe, hlist);
			if (probe_kernel_read(&addr, (void *)(entry + offsetof(struct kprobe, addr)),
					      sizeof(addr)))
				break;
			if (probe_kernel_read(&pre, (void *)(entry + offsetof(struct kprobe, pre_handler)),
					      sizeof(pre)))
				pre = NULL;
			if (probe_kernel_read(&post,
					      (void *)(entry + offsetof(struct kprobe, post_handler)),
					      sizeof(post)))
				post = NULL;
			if (probe_kernel_read(&kname,
					      (void *)(entry + offsetof(struct kprobe, symbol_name)),
					      sizeof(kname)))
				kname = NULL;
			namebuf[0] = 0;
			if (kname && probe_kernel_read(namebuf, kname, sizeof(namebuf) - 1) < 0)
				namebuf[0] = 0;
			sym = kallsyms_lookup((unsigned long)addr, &sz, &off, &mod, fnbuf);
			pr_info("KPROBE #%d addr=%px sym=%s+0x%lx mod=[%s] pre=%px post=%px name=[%s]\n",
				total, addr, sym ? sym : "(不在符号表里)", off, mod ? mod : "-", pre, post,
				namebuf);
			if (shown < 48) {
				ksu_slots_puts("#%d %px %s mod=[%s] pre=%px post=%px nm=[%s]\n", total, addr,
					       sym ? sym : "(no-sym)", mod ? mod : "-", pre, post, namebuf);
				shown++;
			}
			pos = nx.next;
		}
	}
	ksu_slots_puts("KPROBEWALK total=%d\n", total);
	pr_info("KPROBEWALK 收工：一共 %d 个 kprobe\n", total);
}

/* ===== rc47(md §6.90)：改道者落在哪、它前 16 条指令长什么样、要不要把跳板写回本体 =====
 * 第八十九发一手(对照法抓到的)：
 *   write/futex/getpid/reboot 的 `.cfi_jt` 解出来 = **各自本体(MATCH)**；
 *   openat/execve/execveat 的解出来 = `ffffffdc5824a090 / …048 / …060`，**kallsyms 里没有任何符号**。
 *   ⇒ 厂商(或别的什么)没换表项、没挂 kprobe、没走 LSM，而是**改了 CFI 跳板里那条 B 的目标**。
 *   这也解释了此前所有互相矛盾的一手：普通任务照样进得到本体(我们的入口探针命中 119,802 次)
 *   ⇒ 那个改道点是"看一眼再 tail-jump 回本体"；而 escape 过的任务被它直接 -EPERM 掉
 *   ⇒ 本体从未执行(入口/返回探针零命中)、`raw_syscalls` 却有 enter/exit、内核里 `filp_open` 全 0。
 * ★修法就一笔：把跳板那条 B 写回 `B <本体>`(±128MB 范围内，实测 openat 距本体 -16.8MB ⇒ 放得下)，
 *   用 KSU 现成的 `ksu_patch_text()`(sys_call_table 那笔写就是走它，P1..P4+A readback 已验过)。
 *   参数 `fixcfi=1` 才写；不传参时只报告。 */
static int fixcfi;
module_param(fixcfi, int, 0444);
/* 改"正在执行的 text"那一半单独一个开关，默认关(第九十发把它打开过一次，机器当场重启)。 */
static int fixstub;
module_param(fixstub, int, 0444);

static void ksu_cfi_fix_one(const char *name, int nr, int do_stub, int do_slot)
{
	char jtname[KSYM_NAME_LEN + 16];
	unsigned long func, jt, tgt;
	unsigned int w = 0, neww;
	int in_mod_text;
	long imm;
	int i, n;

	func = kallsyms_lookup_name(name);
	n = snprintf(jtname, sizeof(jtname), "%s.cfi_jt", name);
	if (n <= 0 || n >= (int)sizeof(jtname))
		return;
	jt = kallsyms_lookup_name(jtname);
	if (!func || !jt) {
		ksu_slots_puts("CFIFIX %s func=%px jt=%px 认不出(跳过)\n", name, (void *)func, (void *)jt);
		return;
	}
	if (probe_kernel_read(&w, (void *)jt, sizeof(w))) {
		ksu_slots_puts("CFIFIX %s jt=%px 读桩失败\n", name, (void *)jt);
		return;
	}
	if ((w >> 26) != 0x05u) {
		ksu_slots_puts("CFIFIX %s jt=%px 桩不是 B(%08x) ⇒ 这台机不是这个形态，停\n", name,
			       (void *)jt, w);
		return;
	}
	imm = (long)(int)(w << 6) >> 6;
	tgt = jt + 4 * imm;
	if (tgt == func) {
		ksu_slots_puts("CFIFIX %s jt=%px B->本体 ✓ 不用改\n", name, (void *)jt);
		return;
	}
	/* ★两重坑都踩过才定下来的写法：
	 *   ① `module_text_address()` 本树**头里没有声明**(kernel/module.c 里只导出不声明) ⇒ implicit declaration；
	 *   ② 换成头里有声明的 `is_module_text_address()`，构建闸门又报它**不在本机 Module.symvers** ⇒
	 *      直接引用会在 insmod 时以未知符号失败(而且是在真机上才炸)。
	 *   ⇒ 走本文件既有的"只解析地址、按函数指针调用"的路子(见 p_is_module_text_address)。
	 *   是谁的模块，由 KILLSCAN 那份模块表(base/text_size)离线对号，不在这里解引用别人的 struct。 */
	in_mod_text = p_is_module_text_address ? p_is_module_text_address(tgt) : -1;
	pr_info("CFIFIX %s jt=%px 桩 B->%px (本体=%px 差=%ldKB) 在模块文本段=%d\n", name, (void *)jt,
		(void *)tgt, (void *)func, ((long)func - (long)tgt) / 1024, in_mod_text);
	ksu_slots_puts("CFIFIX %s jt=%px B->%px 本体=%px 差=%ldKB 在模块文本段=%d 改道者前 16 条指令:",
		       name, (void *)jt, (void *)tgt, (void *)func,
		       ((long)func - (long)tgt) / 1024, in_mod_text);
	for (i = 0; i < 16; i++) {
		unsigned int x = 0;

		if (probe_kernel_read(&x, (void *)(tgt + 4 * i), sizeof(x))) {
			ksu_slots_puts(" [读断在%d]", i);
			break;
		}
		ksu_slots_puts(" %08x", x);
	}
	ksu_slots_puts("\n");

	/* ===== rc49：把跳板末端那个 `.quad` 解出来 ⇒ 直接看守卫函数本体 =====
	 * 第九十一发读到的跳板是 `LDR x16,[pc,#8] / BR x16 / .quad 0xffffffe451275168`，
	 *   也就是说真正被执行的是**那个 .quad 里的地址**。此前只 dump 了跳板本身(24 字节)，
	 *   没解最后这一跳 ⇒ 离"它按什么条件返回 -EPERM"只差一步。
	 * ★纯读，零风险(第九十/九十一发两次写内存都把机器打 PS_HOLD 重启，读不会)。 */
	{
		unsigned long guard = 0, gs = 0, goff = 0;
		unsigned int g0 = 0;
		char gbuf[KSYM_NAME_LEN + 16];
		char *gmod = NULL;
		const char *gsym;
		int j;

		if (probe_kernel_read(&guard, (void *)(tgt + 8), sizeof(guard)) == 0 && guard) {
			gsym = kallsyms_lookup(guard, &gs, &goff, &gmod, gbuf);
			probe_kernel_read(&g0, (void *)guard, sizeof(g0));
			pr_info("CFIGUARD %s 跳板末端 .quad=%px 符号=%s+0x%lx mod=[%s] 第一条指令=%08x\n",
				name, (void *)guard, gsym ? gsym : "(不在符号表里)", goff,
				gmod ? gmod : "-", g0);
			ksu_slots_puts("CFIGUARD %s quad=%px sym=%s+0x%lx mod=[%s] w0=%08x 前 28 条:", name,
				       (void *)guard, gsym ? gsym : "(no-sym)", goff, gmod ? gmod : "-", g0);
			for (j = 0; j < 28; j++) {
				unsigned int x = 0;

				if (probe_kernel_read(&x, (void *)(guard + 4 * j), sizeof(x))) {
					ksu_slots_puts(" [断在%d]", j);
					break;
				}
				ksu_slots_puts(" %08x", x);
			}
			ksu_slots_puts("\n");
		} else {
			ksu_slots_puts("CFIGUARD %s 解 .quad 失败(tgt+8=%px)\n", name, (void *)(tgt + 8));
		}
	}
	if (!do_stub && !do_slot) {
		ksu_slots_puts("CFIFIX %s 只报告不写\n", name);
		return;
	}
	/* ★★第九十发一手：`fixcfi=1` 那一版**先写桩(改正在执行的 text)再写表项**，结果 insmod 当场把机器
	 *   打重启(证据：ksu_stage.log 停在 `②′ 挂上与否: 1 enable=1` 那行、也就是 insmod 的下一行没出来；
	 *   dmesg.live 里连一条 SLOTTBL/CFIFIX 都没有 ⇒ init 没走到打印，或打印后立刻炸)。
	 *   两笔写里"改 text"是危险的那笔：`ksu_patch_text` 在 KSU 里的用途是写 `__ro_after_init` 的
	 *   **数据页**(sys_call_table slot 42 就是这么写的，P1..P4+A readback 历发全绿)，
	 *   拿它去改**正在被别的 CPU 执行的指令**没有同步(stop_machine/跨 CPU I-cache 维护)，
	 *   而且 aliascheck 那道闸是按数据页验证的。⇒ **默认不做**；要试必须显式 fixstub=1。
	 *   下一发只走下面那条**有先例**的 8 字节数据写。 */
	if (do_stub) {
		neww = (0x05u << 26) | (unsigned int)((((long)func - (long)jt) >> 2) & 0x03FFFFFFu);
		if (ksu_patch_text((void *)jt, &neww, sizeof(neww), KSU_PATCH_TEXT_FLUSH_DCACHE)) {
			ksu_slots_puts("CFIFIX %s 写桩失败(不碰表项)\n", name);
			return;
		}
		w = 0;
		if (probe_kernel_read(&w, (void *)jt, sizeof(w)) == 0 && w == neww)
			ksu_slots_puts("CFIFIX %s 桩已写回 %08x(=B 本体)\n", name, w);
		else
			ksu_slots_puts("CFIFIX %s 桩写完复读=%08x 期望=%08x ⇒ 没落地\n", name, w, neww);
	} else {
		ksu_slots_puts("CFIFIX %s 跳过写桩(do_stub=0)\n", name);
	}

	/* 这条**在这台机上有先例**：把 `sys_call_table[nr]` 直接指向本体(8 字节，写的是
	 *   `__ro_after_init` 的**数据页** —— KSU 对 slot 42 每发都在写，P1..P4 + A readback 历发全绿)。
	 *   第九十发是"改 text 那笔 + 这笔"一起做，机器当场重启 ⇒ 运行期把两笔拆开、各自可关。 */
	if (!do_slot) {
		ksu_slots_puts("CFIFIX %s 跳过写表项(do_slot=0)\n", name);
		return;
	}
	{
		unsigned long tbl = kallsyms_lookup_name("sys_call_table");
		unsigned long slot, old = 0, got = 0;

		if (!tbl) {
			ksu_slots_puts("CFIFIX %s 认不出 sys_call_table ⇒ 不动表项\n", name);
			return;
		}
		slot = tbl + (unsigned long)nr * sizeof(unsigned long);
		if (probe_kernel_read(&old, (void *)slot, sizeof(old))) {
			ksu_slots_puts("CFIFIX %s slot=%d 读不到 ⇒ 不动表项\n", name, nr);
			return;
		}
		if (ksu_patch_text((void *)slot, &func, sizeof(func), KSU_PATCH_TEXT_FLUSH_DCACHE)) {
			ksu_slots_puts("CFIFIX %s slot=%d 写表项失败\n", name, nr);
			return;
		}
		if (probe_kernel_read(&got, (void *)slot, sizeof(got)))
			got = 0;
		pr_info("CFIFIX slot=%d 表项 %px -> %px (本体=%px)%s\n", nr, (void *)old, (void *)got,
			(void *)func, got == func ? " OK" : " 没落地");
		ksu_slots_puts("CFIFIX slot=%d %px->%px 本体=%px %s\n", nr, (void *)old, (void *)got,
			       (void *)func, got == func ? "OK" : "NOT-LANDED");
	}
}

/* ===== rc48：运行期触发口 `/proc/ksu_fixcfi`(0600，只有 root 写得动) =====
 *   `echo 1 > /proc/ksu_fixcfi` ⇒ 只对 openat/execve/execveat 做**表项 8 字节数据写**(这台机有先例那条)；
 *   `echo 2 > /proc/ksu_fixcfi` ⇒ 连"改正在执行的 text 的桩"一起写(第九十发就是两笔一起下之后当场重启)。
 *   结果全部追加进同一份 `/proc/ksu_slots` ⇒ 一次 cat 就把"写之前/写之后"一起拿走。
 * ★为什么要搬到来运行期：危险动作必须排在**所有安全读数之后**，而且要能单独触发 ——
 *   第九十发把两笔写放在 init 里，机器连一条读数都没留下。 */
static struct proc_dir_entry *ksu_fixcfi_pe;

static ssize_t ksu_fixcfi_write(struct file *filp, const char __user *ubuf, size_t cnt, loff_t *ppos)
{
	char c = 0;

	if (cnt < 1)
		return -EINVAL;
	if (copy_from_user(&c, ubuf, 1))
		return -EFAULT;
	ksu_slots_puts("=== ksu_fixcfi 触发 c=%c ===\n", c);
	if (c == '1' || c == '2' || c == '3') {
		int do_stub = (c == '2' || c == '3');
		int do_slot = (c == '1' || c == '2');

		/* ★第九十三发把两次重启的因由解释清楚了(一手：CFIGUARD 解出来
		 *   `sym=__cfi_check+0x168 mod=[vr]`)：
		 *   ① 改道者是**模块 vr**，它的手法是"把内核 .cfi_jt 表里 openat/execve/execveat 三条的
		 *      `B` 目标改成 vr 自己的入口垫(pad)"，**不碰 sys_call_table**(所以历发反检测都干净)；
		 *   ② 出厂对照(vmlinux.elf)证明 `.cfi_jt` 原本就是 `B <本体>`；
		 *   ③ 我那两笔"把 sys_call_table[nr] 直接写成本体地址"之所以当场 PS_HOLD 重启，
		 *      是因为 **KCFI 的间接调用检查要求表里放的是"带类型 id 的地址取得形式"**
		 *      (KSU 自己写 slot 42 放的是 `ksu_syscall_dispatcher`——那是它**模块内**的函数，
		 *       取地址时编译器已经在它前面放好了 pad ⇒ 合法)；把**核心内核函数的裸本体地址**
		 *       塞进表里 ⇒ 调用点校验失败 ⇒ `cfi_fail()` ⇒ panic ⇒ PS_HOLD。
		 *   ⇒ 所以 `c=3`(**只改桩的 B 目标，表项一个字都不动**)才是与出厂状态语义等价的那一笔，
		 *     也是唯一还没试过、且推理上不会触发 cfi_fail 的写法。 */
		ksu_cfi_fix_one("__arm64_sys_openat", 56, do_stub, do_slot);
		ksu_cfi_fix_one("__arm64_sys_execve", 221, do_stub, do_slot);
		ksu_cfi_fix_one("__arm64_sys_execveat", 281, do_stub, do_slot);
		/* rc57(§6.116)：可见性钩子(stat/faccessat)要调原实现 ⇒ 这两条桩也一起处理 */
		ksu_cfi_fix_one("__arm64_sys_newfstatat", 79, do_stub, do_slot);
		ksu_cfi_fix_one("__arm64_sys_faccessat", 48, do_stub, do_slot);
	} else if (c == '4') {
		/* rc62(#73-B)：c=4 = 只写新加的三条，而且 do_slot 硬编成 0(表项一个字都不动)。
		 *   为什么另开一个值而不并进 c=3：交付流程每发都在跑 c=3 那五条，新增的写必须能
		 *   单独触发、单独归因 —— 万一这一笔把机器打重启，凶手没有第二种解释。
		 *   号是从本机 uapi 头里读出来的(不是记忆)：clone=220 setuid=146 setresuid=147。 */
		ksu_slots_puts("fixcfi c=4：#73 三条(clone/setuid/setresuid)，只改桩 B ⇒ do_slot=0\n");
		ksu_cfi_fix_one("__arm64_sys_clone", 220, 1, 0);
		ksu_cfi_fix_one("__arm64_sys_setuid", 146, 1, 0);
		ksu_cfi_fix_one("__arm64_sys_setresuid", 147, 1, 0);
	} else {
		ksu_slots_puts("fixcfi: 认 1(只写表项,已知会 panic)/2(两笔都写)/3(只改桩=与出厂等价)/4(只改桩：#73 那三条)，这次什么也没写\n");
	}
	return cnt;
}

static const struct file_operations ksu_fixcfi_fops = {
	.owner = THIS_MODULE,
	.write = ksu_fixcfi_write,
	.llseek = no_llseek,
};

/* ===== rc64(#81)：运行期改"王座(Manager)那条 root 的 SELinux 域"，触发口 `/proc/ksu_mgrdomain` =====
 * 为什么只能这么改：`policy/allowlist.c` 里 `is_uid_manager(uid) ⇒ goto use_default`，
 *   所以**给 Manager 写 SET_APP_PROFILE 永远不会生效**(§6.168 一手)，它只能吃 default_root_profile；
 *   而 `KSU_DEFAULT_SELINUX_DOMAIN = "u:r:" KERNEL_SU_DOMAIN ":s0"` 这个域在本机策略里不存在，
 *   `setup_selinux()` 对不存在的域是"保持起点域"(#53 的读数) ⇒ 官方 Manager 的 root 服务起来之后
 *   域还停在 `untrusted_app`(§6.168)，官方 UI 那几格(弹窗/libsu)因此差最后一块。
 * 形状：**写一行=设成那行**，`echo ? > 这个口`=把当前值打进 `/proc/ksu_slots`(我们每发都整份导出来)。
 * ★默认什么都不做：不写这个口 ⇒ 与 rc63 完全一致(交付行为零变化)，同窗 `?`/设值/复位 就是单变量 A/B。
 * ★为什么不是 module_param：`core/init.c` 里 `kobject_del(&THIS_MODULE->mkobj.kobj)` 把
 *   `/sys/module/kernelsu/` 整个摘走 ⇒ 运行时没有参数写口(§6.178⑤ 那条一手)。 */
extern void ksu_set_mgr_domain(const char *d);
extern const char *ksu_get_mgr_domain(void);

static struct proc_dir_entry *ksu_mgrdomain_pe;

static ssize_t ksu_mgrdomain_write(struct file *filp, const char __user *ubuf, size_t cnt, loff_t *ppos)
{
	char buf[96];
	size_t n = cnt < sizeof(buf) - 1 ? cnt : sizeof(buf) - 1;

	if (copy_from_user(buf, ubuf, n))
		return -EFAULT;
	buf[n] = 0;
	if (n && buf[n - 1] == '\n')		/* echo 带进来的换行不算域名的一部分 */
		buf[n - 1] = 0;
	if (buf[0] == '?') {
		ksu_slots_puts("MGRDOMAIN 现在=[%s]\n", ksu_get_mgr_domain());
		return cnt;
	}
	if (!buf[0]) {
		ksu_slots_puts("MGRDOMAIN 空串 ⇒ 什么都不改\n");
		return cnt;
	}
	ksu_set_mgr_domain(buf);
	ksu_slots_puts("MGRDOMAIN 写入[%s] ⇒ 现在=[%s]\n", buf, ksu_get_mgr_domain());
	return cnt;
}

static const struct file_operations ksu_mgrdomain_fops = {
	.owner = THIS_MODULE,
	.write = ksu_mgrdomain_write,
	.llseek = no_llseek,
};

/* ===== rc51：把 `init_uts_ns.name.sysname` 修回 "Linux"(触发口 `/proc/ksu_fixuts`) =====
 *   窗口 97/98 两次一手：payload 那笔越界写把 sysname 的**最后一字节**改成 NUL(`uname -s`=`Linu`)，
 *   于是 ART 在**每个新进程**的静态初始化里 `Check failed: strcmp(uts.sysname,"Linux")==0` ⇒ SIGABRT
 *   ⇒ 这一发窗口里任何 app 都起不来，路线 C/UI 判据全被打成"零报告"(看着像管理面的 bug)。
 *   ★用户态修不了(第五十九发实测)：这台机把 `/proc/sys/kernel/ostype` 编成 **0444**
 *   (同目录 hostname / printk_ratelimit 还是 0644)，而 sysctl 的写权限是按表里的 `.mode` 判的，
 *   **uid 0 也一样 EACCES** —— stage v55 那句 `echo Linux > /proc/sys/kernel/ostype` 的回执是
 *   `can't create /proc/sys/kernel/ostype: Permission denied`。⇒ 只剩内核侧这一笔。
 * ★不猜偏移：`struct uts_namespace` 里 `name` 前面那个 `struct kref` 大小随版本变，
 *   所以在头 512 字节里**按字段间距自己咬合**：sysname 处是 "Linu"、+130 是 release("5.4")、
 *   +260 是 machine("aarch64") —— 三个字段同时对上才算认出来，认不出来一个字都不写。
 * ★写的手法用现成的 `ksu_patch_text()`：它对 `sys_call_table`(那块是 `__ro_after_init`)已经能落地
 *   (P1..P4+A readback 历发绿)，而 `.data` 里的 init_uts_ns 权限只会更低；这不是 text 改道，
 *   不碰任何间接调用点 ⇒ 没有第九十/九十一发那种 cfi_fail 风险。 */
static struct proc_dir_entry *ksu_fixuts_pe;

static int ksu_uts_find(const char *b, int len)
{
	int i;

	for (i = 0; i + 260 + 8 <= len; i++) {
		if (!memcmp(b + i, "Linu", 4) && !memcmp(b + i + 130, "5.4", 3) &&
		    !memcmp(b + i + 260, "aarch64", 7))
			return i;
	}
	/* 万一 sysname 被打得更花(前 4 个字节都不对)：从 release 反推，但仍要 machine 佐证 */
	for (i = 130; i + 130 + 8 <= len; i++) {
		if (!memcmp(b + i, "5.4", 3) && !memcmp(b + i + 130, "aarch64", 7) && i >= 130)
			return i - 130;
	}
	return -1;
}

static void ksu_uts_fix(int do_write)
{
	static char b[512];
	unsigned long base = kallsyms_lookup_name("init_uts_ns");
	int off;

	if (!base) {
		ksu_slots_puts("UTS 认不出 init_uts_ns ⇒ 不动\n");
		return;
	}
	if (probe_kernel_read(b, (void *)base, sizeof(b))) {
		ksu_slots_puts("UTS 读 init_uts_ns(%px) 失败 ⇒ 不动\n", (void *)base);
		return;
	}
	off = ksu_uts_find(b, sizeof(b));
	if (off < 0) {
		ksu_slots_puts("UTS base=%px 前 %zu 字节里没有 sysname/release/machine 三件套 ⇒ 不动\n",
			       (void *)base, sizeof(b));
		return;
	}
	ksu_slots_puts("UTS base=%px off=%d sysname=[%.8s] release=[%.20s] machine=[%.16s]\n",
		       (void *)base, off, b + off, b + off + 130, b + off + 260);
	if (!memcmp(b + off, "Linux", 6)) {
		ksu_slots_puts("UTS sysname 本来就是 Linux ⇒ 不写\n");
		return;
	}
	if (!do_write) {
		ksu_slots_puts("UTS 只报告(要写：echo 1 > /proc/ksu_fixuts)\n");
		return;
	}
	if (ksu_patch_text((void *)(base + off), "Linux", 6, KSU_PATCH_TEXT_FLUSH_DCACHE)) {
		ksu_slots_puts("UTS 写失败 ⇒ 不动\n");
		return;
	}
	memset(b, 0, sizeof(b));
	if (probe_kernel_read(b, (void *)base, sizeof(b)) || memcmp(b + off, "Linux", 6))
		ksu_slots_puts("UTS 写完复读不是 Linux ⇒ 没落地\n");
	else
		ksu_slots_puts("UTS ★sysname 已写回 Linux(复读通过；新起的 app 进程应当不再 abort)\n");
}

static ssize_t ksu_fixuts_write(struct file *filp, const char __user *ubuf, size_t cnt, loff_t *ppos)
{
	char c = 0;

	if (cnt < 1)
		return -EINVAL;
	if (copy_from_user(&c, ubuf, 1))
		return -EFAULT;
	ksu_slots_puts("=== ksu_fixuts 触发 c=%c ===\n", c);
	ksu_uts_fix(c == '1');
	return cnt;
}

static const struct file_operations ksu_fixuts_fops = {
	.owner = THIS_MODULE,
	.write = ksu_fixuts_write,
	.llseek = no_llseek,
};

void ksu_uts_report(void)
{
	if (!ksu_fixuts_pe)
		ksu_fixuts_pe = proc_create("ksu_fixuts", 0600, NULL, &ksu_fixuts_fops);
	ksu_slots_puts("uts proc=%s\n", ksu_fixuts_pe ? "ok" : "FAIL");
	ksu_uts_fix(0);   /* ★init 只报告，一笔都不写(老规矩：危险动作排在所有安全读数之后，且可单独触发) */
}

/* ===== rc61-A(#73 第一步，纯读)：把 __arm64_sys_*.cfi_jt 那一整块扫一遍，数出 vr 到底管几条 =====
 * 为什么要全表(§6.167)：escape 过的任务 {clone 220, setuid 146, setresuid 147} 吃 -EPERM，而
 *   `__arm64_sys_clone` 的 kretprobe **零命中**(同语义的 clone3 十二格全过)；但我们一直只**点查** 5 条桩
 *   (openat/execve/execveat 落在 vr 上，newfstatat/faccessat 干净) ⇒ "vr 到底管哪些号"从来没数过。
 * ★分辨力只用一条(§6.90 那手教训)：**"B 没指着自己的本体"不算被改** —— 出厂形态本来就常是
 *   `B <桩>` + `桩+8 的 .quad <本体>`。这里只认"**B 目标**或**那个 .quad 落点**解析出来模块名 == vr"。
 *   这条判据在已知的 5 条上给出 3 命中 / 2 干净，才是能用的判据。
 * ★便宜在哪儿：`.cfi_jt` 里 `__arm64_sys_*` 那些项是**挨着排的**(历发 kallsyms 里地址逐个 +4)，
 *   所以从几个锚的 min-32KB 扫到 max+32KB 就够；每格先 probe_kernel_read，只有"确实是一条 B"才去
 *   kallsyms_lookup ⇒ 一万六千格几十毫秒。 */
static int ksu_cfiscan_seen, ksu_cfiscan_hits, ksu_cfiscan_printed;
static struct proc_dir_entry *ksu_cfiscan_pe;

static void ksu_cfi_jt_one(unsigned long jt)
{
	unsigned int w = 0;
	unsigned long tgt, q = 0, sz = 0, off = 0, qsz = 0, qoff = 0;
	char *mod = NULL, *qmod = NULL;
	char jbuf[KSYM_NAME_LEN + 16], tbuf[KSYM_NAME_LEN + 16], qbuf[KSYM_NAME_LEN + 16];
	const char *jsym, *qsym;
	int policed = 0;
	char who[96];

	if (probe_kernel_read(&w, (void *)jt, sizeof(w)))
		return;
	if ((w >> 26) != 0x05u)
		return; /* 不是 B ⇒ 不是桩，跳过(不查符号，省时间) */
	jsym = kallsyms_lookup(jt, &sz, &off, &mod, jbuf);
	if (!jsym || off != 0 || !strstr(jsym, ".cfi_jt") || strncmp(jsym, "__arm64_sys_", 12))
		return;
	ksu_cfiscan_seen++;
	tgt = jt + 4 * ((long)(int)(w << 6) >> 6);
	who[0] = 0;
	qsym = NULL;
	if (kallsyms_lookup(tgt, &sz, &off, &mod, tbuf) && mod && !strcmp(mod, "vr")) {
		policed = 1;
		snprintf(who, sizeof(who), "B->%s+0x%lx [vr]", tbuf, off);
	} else if (probe_kernel_read(&q, (void *)(tgt + 8), sizeof(q)) == 0 && q) {
		qmod = NULL;
		qsym = kallsyms_lookup(q, &qsz, &qoff, &qmod, qbuf);
		if (qsym && qmod && !strcmp(qmod, "vr")) {
			policed = 1;
			snprintf(who, sizeof(who), "B->%px(桩) .quad->%s+0x%lx [vr]", (void *)tgt, qbuf, qoff);
		}
	}
	(void)qsym;
	if (policed) {
		ksu_cfiscan_hits++;
		if (ksu_cfiscan_printed < 300) {
			ksu_slots_puts("VRCFI *被管 %-40s jt=%px %s\n", jsym, (void *)jt, who);
			ksu_cfiscan_printed++;
		}
	} else if (!strncmp(jsym, "__arm64_sys_clone", 17) || !strncmp(jsym, "__arm64_sys_setuid", 18) ||
		   !strncmp(jsym, "__arm64_sys_setresuid", 21) || !strncmp(jsym, "__arm64_sys_setgid", 18)) {
		/* 对照：这一发最关心的四条，**没被管也要留字**("没这条读数"和"读了说没有"是两回事) */
		ksu_slots_puts("VRCFI (未管) %-36s jt=%px B->%px %s\n", jsym, (void *)jt, (void *)tgt,
			       tbuf[0] ? tbuf : "(解不出)");
	}
}

static void ksu_cfi_scan(void)
{
	static const char *const anchors[] = { "__arm64_sys_openat.cfi_jt", "__arm64_sys_execve.cfi_jt",
					       "__arm64_sys_newfstatat.cfi_jt",
					       "__arm64_sys_getdents64.cfi_jt",
					       "__arm64_sys_io_setup.cfi_jt" };
	unsigned long lo = 0, hi = 0, a, span;
	int i;

	ksu_cfiscan_seen = ksu_cfiscan_hits = ksu_cfiscan_printed = 0;
	for (i = 0; i < (int)(sizeof(anchors) / sizeof(anchors[0])); i++) {
		a = kallsyms_lookup_name(anchors[i]);
		if (!a) {
			ksu_slots_puts("VRCFI 锚 %s 认不出(这台机不叫这个名)\n", anchors[i]);
			continue;
		}
		if (!lo || a < lo)
			lo = a;
		if (a > hi)
			hi = a;
	}
	if (!lo) {
		ksu_slots_puts("VRCFI 一个锚都没有 ⇒ 不扫\n");
		return;
	}
	span = 0x8000; /* 两侧各 32KB：整块 __arm64_sys_* 桩在里面(实测最远两条相距 ~1.6KB) */
	lo -= span;
	hi += span;
	ksu_slots_puts("VRCFI begin 范围=%px..%px 步长 4 ⇒ %lu 格\n", (void *)lo, (void *)hi,
		       (hi - lo) / 4);
	for (a = lo; a < hi; a += 4)
		ksu_cfi_jt_one(a);
	ksu_slots_puts("VRCFI 结束：认出 __arm64_sys_ 桩=%d 条，落在 vr 里的=%d 条(打印上限 300)\n",
		       ksu_cfiscan_seen, ksu_cfiscan_hits);
	if (ksu_cfiscan_seen < 300)
		ksu_slots_puts("VRCFI [!] 只认到 %d 条(<300) ⇒ 块比预想大或散，下一发把 span 调大再看\n",
			       ksu_cfiscan_seen);
	pr_info("VRCFI done：桩=%d 被 vr 管=%d\n", ksu_cfiscan_seen, ksu_cfiscan_hits);
}

static ssize_t ksu_cfiscan_write(struct file *filp, const char __user *ubuf, size_t cnt, loff_t *ppos)
{
	char c = 0;

	if (cnt < 1)
		return -EINVAL;
	if (copy_from_user(&c, ubuf, 1))
		return -EFAULT;
	ksu_slots_puts("=== ksu_cfiscan 触发 c=%c(纯读) ===\n", c);
	ksu_cfi_scan();
	return cnt;
}

static const struct file_operations ksu_cfiscan_fops = {
	.owner = THIS_MODULE,
	.write = ksu_cfiscan_write,
	.llseek = no_llseek,
};

void ksu_pcode_report(void)
{
	size_t i;

	if (!pcode)
		return;
	pr_info("PCODE 进入\n");
	ksu_slots_puts("PCODE begin\n");
	/* rc48：运行时触发口。insmod 那一刻只**报告**(fixcfi 默认 0)，等 PC 侧用阶梯确认过
	 *   "这个任务确实还是 EPERM"之后，再 `echo 1 > /proc/ksu_fixcfi` 单独下那一笔
	 *   **表项 8 字节数据写**(有先例的那条)，然后立刻复跑阶梯。
	 *   为什么搬到运行期：第九十发把两笔写都放在 init 里，机器当场重启，
	 *   什么读数都没留下 ⇒ 危险动作要排在所有安全读数**之后**，而且要可以单独触发。 */
	if (!ksu_fixcfi_pe)
		ksu_fixcfi_pe = proc_create("ksu_fixcfi", 0600, NULL, &ksu_fixcfi_fops);
	ksu_slots_puts("fix proc=%s\n", ksu_fixcfi_pe ? "ok" : "FAIL");
	/* rc61-A(#73)：全表扫"哪些 __arm64_sys_ 桩落在 vr 里"的触发口(纯读，一个字都不写)。 */
	if (!ksu_cfiscan_pe)
		ksu_cfiscan_pe = proc_create("ksu_cfiscan", 0600, NULL, &ksu_cfiscan_fops);
	ksu_slots_puts("cfiscan proc=%s\n", ksu_cfiscan_pe ? "ok" : "FAIL");
	/* rc64(#81)：王座默认域的运行期写口(默认不动任何东西，见 ksu_mgrdomain_write 上面那段)。 */
	if (!ksu_mgrdomain_pe)
		ksu_mgrdomain_pe = proc_create("ksu_mgrdomain", 0600, NULL, &ksu_mgrdomain_fops);
	ksu_slots_puts("mgrdomain proc=%s 起点域=[%s]\n", ksu_mgrdomain_pe ? "ok" : "FAIL",
		       ksu_get_mgr_domain());
	for (i = 0; i < sizeof(ksu_pcode_funcs) / sizeof(ksu_pcode_funcs[0]); i++)
		ksu_pcode_one(ksu_pcode_funcs[i]);
	/* ===== rc45：CFI 跳板(`.cfi_jt`)有没有被改道 =====
	 * 第八十八发一手：`sys_call_table[56]` 里那个"原值"其实是**一条 4 字节 `B`**(不是函数本体)，
	 *   所以"槽里是原值"只证明**这条 B 指令的地址**没被换，**B 跳到哪儿**才是真正决定
	 *   "`__arm64_sys_openat` 会不会被执行"的那一笔。第八十八发的三条一手证据把落点逼到这里：
	 *     ① `raw_syscalls` 有 `sys_enter: NR 56`、`sys_exit = -1`(arm64 5.4 里 tracepoint 在
	 *        `invoke_syscall` **之前**，所以"进了派发但没进函数"是这个形状)；
	 *     ② 我们挂在 `__arm64_sys_openat` **本体**上的入口探针对这个任务零命中，而对别的任务
	 *        同一时间命中 119,802 次；
	 *     ③ 同一个任务在内核里跑 `kern_path/inode_permission/filp_open` **全部为 0**(成功)。
	 *   ⇒ 三条合起来只剩"派发去的地方不是本体"。
	 * ★判据用**对照法**，不用"指不指向本体"：本机每个 `.cfi_jt` 解出来都指向 `ffffffe21864a0xx`
	 *   这一片(与本体差 ~30MB)，看着像正常的 veneer 布局 ⇒ 光比 `func` 会全部"不匹配"而失去分辨力。
	 *   所以这里同时解 **escape 之后还能用的** syscall(write/futex/getpid)与**解不开的**
	 *   (openat/execve/execveat)：两组形态一致 ⇒ 跳板干净，这条再排除；只有后一组指向别处
	 *   (尤其落在某个模块的地址区间)⇒ 当场抓到改道者，修法是把那 4 字节写回 `B <本体>`
	 *   (我们已经有 `ksu_patch_text` 这条现成的写路径)。 */
	ksu_cfi_check("__arm64_sys_write");
	ksu_cfi_check("__arm64_sys_futex");
	ksu_cfi_check("__arm64_sys_getpid");
	ksu_cfi_check("__arm64_sys_openat");
	ksu_cfi_check("__arm64_sys_execve");
	ksu_cfi_check("__arm64_sys_execveat");
	ksu_cfi_check("__arm64_sys_reboot");
	/* rc47：报告三个被改道的桩落在哪、长什么样；传 `fixcfi=1` 才写回。
	 *   nr 是本机 arm64 通用号(openat=56/execve=221/execveat=281，与 SLOTTBL 那张表同一份)。
	 * ★rc57(§6.116)：再加 **newfstatat=79 / faccessat=48** 两条 —— 第一百一十七发一手：
	 *   开 `ksu_hook_mask=0x1a`(位 3/4=可见性钩子)之后，app 里第一句 `access("/system/bin/su")`
	 *   就把机器打死(报告停在 `SUPROBE 起点`，3ms 内掉线)。sucompat 的探测伪装是
	 *   `ksu_syscall_table[orig_nr](regs)` **间接调用原实现**，而 vr 的手法正是"改 .cfi_jt 桩的 B 目标"
	 *   ⇒ 头号嫌疑=这两条桩也被改到 vr 的垫上，我们从钩子里调进去就 cfi_fail/走飞。
	 *   默认(fixcfi=0)只报告，`echo 3 > /proc/ksu_fixcfi` 才与那三条一起只写桩(不碰表项)。 */
	ksu_cfi_check("__arm64_sys_newfstatat");
	ksu_cfi_check("__arm64_sys_faccessat");
	ksu_cfi_fix_one("__arm64_sys_openat", 56, fixstub, fixcfi);
	ksu_cfi_fix_one("__arm64_sys_execve", 221, fixstub, fixcfi);
	ksu_cfi_fix_one("__arm64_sys_execveat", 281, fixstub, fixcfi);
	ksu_cfi_fix_one("__arm64_sys_newfstatat", 79, fixstub, fixcfi);
	ksu_cfi_fix_one("__arm64_sys_faccessat", 48, fixstub, fixcfi);
	pr_info("PCODE 收工\n");
	ksu_slots_puts("PCODE done\n");
	/* rc44 正对照：此刻这个任务还是 insmod 的发起者(born-root，什么都没被拦)，
	 *   先跑一遍同样的探针 ⇒ 若这一遍就非 0，那是仪器/内核的问题，与 escape 无关。 */
	ksu_open_probe_run("insmod-task");
	if (!ksu_probe_pe)
		ksu_probe_pe = proc_create("ksu_openprobe", 0600, NULL, &ksu_probe_fops);
	ksu_slots_puts("PROBE(insmod) %s proc=%s\n", ksu_probe_buf, ksu_probe_pe ? "ok" : "FAIL");
	ksu_kprobe_walk();   /* rc43：debugfs 挂不起来(内核 cmdline 上 debugfs=off) ⇒ 自己走哈希表 */
}

void ksu_killscan_run(void)
{
	ksu_lsmhook_report(); /* rc41：先看钩子链，再看表(同一份 /proc 读数) */
	ksu_slottbl_report();   /* rc37：读数顺手打，不另加 init.c 钩子 */
	ksu_pcode_report();     /* rc42：入口找 BRK(kprobe 占位) */
	ksu_uts_report();       /* rc51：报告 uts.sysname(窗口 97/98 的"app 全起不来"就是它) */
	unsigned long fs, mh_addr;
	struct list_head *mh;
	struct module *mod;
	int seen = 0, hits = 0, mods_ok = 0;

	fs = ksu_sym_addr("force_sig");
	ksu_fs_addr = fs;
	mh_addr = ksu_sym_addr("modules");
	pr_info("KILLSCAN enter: force_sig=%px modules=%px scanmod=[%s] scanall=%d scannop=%d | offsetof list=%zu name=%zu core_layout=%zu | layout.base=%zu layout.text_size=%zu\n",
		(void *)fs, (void *)mh_addr, scanmod ? scanmod : "(null)", scanall, scannop,
		offsetof(struct module, list), offsetof(struct module, name),
		offsetof(struct module, core_layout), offsetof(struct module_layout, base),
		offsetof(struct module_layout, text_size));
	if (!fs || !mh_addr) {
		pr_info("KILLSCAN: force_sig/modules 没解析到 ⇒ 收工\n");
		return;
	}
	mh = (struct list_head *)mh_addr;
	/* 不加 module_mutex：这是**我们自己 insmod 的当下**，没人同时在装卸模块；
	 * 而拿锁要走 kallsyms 找 module_mutex，反而多一处会读错的地方。跑飞由上面两把尺子兜。 */
	list_for_each_entry(mod, mh, list) {
		unsigned char *text;
		unsigned int tsize, i;
		void *first;

		if (++seen > 512) {
			pr_info("KILLSCAN: 看了 512 个还没走完 ⇒ 链表读飞了，停\n");
			break;
		}
		if (mod->name[0] == 0 ||
		    strnlen(mod->name, MODULE_NAME_LEN) >= MODULE_NAME_LEN) {
			pr_info("KILLSCAN: 第 %d 个的名字读飞 ⇒ struct module 布局不对，停\n",
				seen);
			break;
		}
		mods_ok++;
		if (!scanall && scanmod && scanmod[0] && strcmp(mod->name, scanmod))
			continue;
		text = mod->core_layout.base;
		tsize = mod->core_layout.text_size;
		if (!text || tsize < 4 || tsize > (8u << 20)) {
			pr_info("KILLSCAN: 模块[%s] base=%px text_size=%u ⇒ 数值不像话，跳过\n",
				mod->name, text, tsize);
			continue;
		}
		/* ★§6.69 那一格：LR=base+0x408 ⇒ 调用点是 base+0x404。把它的指令解剖出来，
		 *   并顺着 veneer 再跳一次看真目标到底是不是 force_sig。 */
		{
			static const unsigned int probe[] = { 0x404, 0x400, 0x408 };
			unsigned int k;
			for (k = 0; k < ARRAY_SIZE(probe) && probe[k] + 4 <= tsize; k++) {
				unsigned int off = probe[k];
				unsigned long tgt = ksu_insn_target(text + off, text, text + tsize);
				pr_info("KILLSCAN  解剖 %s+%#x: word=%08x 目标=%px%s%s\n",
					mod->name, off, *(u32 *)(text + off), (void *)tgt,
					tgt == fs ? " <= 就是 force_sig!" : "",
					(tgt && (tgt < (unsigned long)text || tgt >= (unsigned long)(text + tsize)))
						? " (模块外)" : "");
			}
		}
		if (!strcmp(mod->name, scanmod ? scanmod : "?")) {
			ksu_gk_text = text;
			ksu_gk_lo = (unsigned long)text;
			ksu_gk_hi = (unsigned long)(text + tsize);
			INIT_WORK(&ksu_guard_work, ksu_guard_work_fn);
			/* ①预置：只验 §6.70 算出来的那一格，三条签名全对才挂 */
			if (killguard && tsize > KSU_GUARD_OFF + 8) {
				u32 a = *(u32 *)(text + KSU_GUARD_OFF - 8);
				u32 b = *(u32 *)(text + KSU_GUARD_OFF - 4);
				u32 c = *(u32 *)(text + KSU_GUARD_OFF);

				pr_info("KILLGUARD: 预置检查 %s+%#x 三连=%08x %08x %08x (要 %08x %08x 低位 %08x)%s",
					mod->name, KSU_GUARD_OFF, a, b, c,
					KSU_INSN_LDR_X8 | 8, KSU_INSN_CBZ_X8_8, KSU_INSN_BLR_X8,
					"\n");
				if (c == KSU_INSN_BLR_X8 && b == KSU_INSN_CBZ_X8_8 &&
				    (a & 0xFFC0001Fu) == (KSU_INSN_LDR_X8 | 8))
					ksu_arm_site(mod->name, text, KSU_GUARD_OFF, "预置偏移");
				else
					pr_info("KILLGUARD: 预置偏移签名不符 ⇒ 不挂，等 force_sig 现学%s",
						"\n");
			}
			/* ②现学：force_sig 上挂个只读探针(它本来就只在被杀时走一次，不是热路径) */
			if (killguard && !ksu_fs_kp.addr) {
				ksu_fs_kp.pre_handler = ksu_fs_pre;
				ksu_fs_kp.addr = (kprobe_opcode_t *)fs;
				if (register_kprobe(&ksu_fs_kp))
					pr_info("KILLGUARD: force_sig 学习探针没挂上%s", "\n");
				else
					pr_info("KILLGUARD: 已挂 force_sig 学习探针(等第一次 sig==9 现学报址)%s",
						"\n");
			}
		}
		first = scan_call_to(text, tsize, (void *)fs);
		pr_info("KILLSCAN: 模块[%s] base=%px text_size=%u scan_call_to 首个命中=+%#lx\n",
			mod->name, text, tsize,
			first ? (unsigned long)((char *)first - (char *)text) : ~0UL);
		for (i = 0; i + 4 <= tsize; i += 4) {
			u32 w = *(u32 *)(text + i);
			s32 imm;
			unsigned long tgt;

			if ((w & 0xFC000000u) != 0x94000000u) /* BL */
				continue;
			imm = (s32)((w & 0x03FFFFFFu) << 6) >> 6;
			tgt = (unsigned long)(text + i) + ((long)imm << 2);
			if (tgt != fs) {
				/* veneer：第一跳落在模块自己里面 ⇒ 跟着再跳一次 */
				if (tgt >= (unsigned long)text && tgt < (unsigned long)(text + tsize)) {
					unsigned long t2 = ksu_insn_target((unsigned char *)tgt, text,
								   text + tsize);
					if (t2 == fs) {
						hits++;
						pr_info("KILLSCAN  ★★★ %s+%#x: bl veneer(%#lx)->force_sig  word=%08x\n",
							mod->name, i, tgt - (unsigned long)text, w);
						if (scannop) {
							u32 nopw = 0xd503201fu;
							int rc = ksu_patch_text(text + i, &nopw, sizeof(nopw),
										KSU_PATCH_TEXT_FLUSH_DCACHE);
							pr_info("KILLSCAN  NOP 写回 %s+%#x rc=%d 读回=%08x\n",
								mod->name, i, rc, *(u32 *)(text + i));
						}
					}
				}
				continue;
			}
			hits++;
			pr_info("KILLSCAN  ★★★ %s+%#x: bl force_sig  word=%08x  上一条=%08x\n",
				mod->name, i, w,
				i >= 4 ? *(u32 *)(text + i - 4) : 0u);
			if (!scannop)
				continue;
			{
				u32 nopw = 0xd503201fu; /* AARCH64_NOP */
				int rc = ksu_patch_text(text + i, &nopw, sizeof(nopw),
							KSU_PATCH_TEXT_FLUSH_DCACHE);
				pr_info("KILLSCAN  NOP 写回 %s+%#x rc=%d 读回=%08x\n",
					mod->name, i, rc, *(u32 *)(text + i));
			}
		}
	}
	pr_info("KILLSCAN 收工：链表里认出名堂 %d 个模块，命中 bl->force_sig 共 %d 处，killguard=%d armed=%d scanmod=[%s] base=%px..%px\n",
		mods_ok, hits, killguard, atomic_read(&ksu_guard_armed),
		scanmod ? scanmod : "(空)", (void *)ksu_gk_lo, (void *)ksu_gk_hi);
}

/* ===== rc35(md §6.80)：把驱动 fd 补装进指定任务(官方 Manager 用) =====
 * 为什么需要：官方 v2.0.0 管理器拿 fd 只靠 `scan_driver_fd()` 扫自己 /proc/self/fd 找
 *   "[ksu_driver]"，native 层**没有任何 reboot 超级调用**(逐字读过 ksu.cc/ksu.h 全文)。
 *   我们晚加载 + 不挂 syscall hook ⇒ 它没有 fd ⇒ 显示"版本 -1 过低"并锁死列表页。
 * ★踩过的坑(rc34 就是这么废的)：**干活不能写在 param setter 里**。参数是在 load_module 早期
 *   解析的，那时 dev_syms 的符号还没解析 ⇒ `task_work_add` 转发返回 -ENOSYS ⇒
 *   整个 insmod 以 "Function not implemented" 失败。⇒ setter 只存 pid，真正的排队放到
 *   `ksu_fd_install_run()`，由 core/init.c:202(killscan 旁边，符号层已热)调用。
 * ★引用安全：`pid_task()` 只在 RCU 读临界区内使用(5.4 的 task_struct 是 RCU-free) ⇒ 不需要
 *   get_task_struct/put_task_struct(这俩本机 Module.symvers 里**未导出**)。
 * ★谁能设这个参数 = 能 insmod 的人(root)；fd 到手后每个 ioctl 仍受内核 perm_check 约束。 */
/* proc_fs.h / uaccess.h 已提到文件顶部(rc40)：这里原来重复 include 过一次。 */

static struct proc_dir_entry *ksu_install_fd_pe;

extern int ksu_install_fd(void);   /* supercall/supercall.h:22，同模块内非静态 */

struct ksu_fd_install_tw {
	struct callback_head cb;
	pid_t pid;
};

static void ksu_fd_install_tw_func(struct callback_head *cb)
{
	struct ksu_fd_install_tw *tw = container_of(cb, struct ksu_fd_install_tw, cb);
	int nfd;

	/* ★10-22 22:4x（md §6.394）：这个回调可能是在**目标自己的 do_exit 收尾**里跑的——
	 *   `kernel/exit.c` 里 `exit_files(tsk)`(855 行，它把 `tsk->files = NULL`，fs/file.c:443) 早于
	 *   `exit_task_work(tsk)`(860 行)。而 `ksu_install_fd()` → `get_unused_fd_flags()` →
	 *   `__alloc_fd()`(fs/file.c:480) 第一行就 `spin_lock(&files->file_lock)`，**整条链没有 !files 防护**
	 *   ⇒ 对着 NULL 加锁＝踩空指针。`task_work_add()` 只拒"排队那一刻已 PF_EXITING"的目标，
	 *   "排队时活着、随后退出"这一路拒不掉，而 root 侧写 `/proc/ksu_install_fd` 传的 pid 是用户态挑的
	 *   （实测：`pidof zygote64` 会返回 zygote 刚 fork、还没改名的瞬时子进程）⇒ 护栏必须在这儿。 */
	if (unlikely(!current->files)) {
		pr_err("KSUFDINST 触发口放弃 pid=%d comm=[%s]：它的 files 已经没了(正在退出)⇒ 硬装会踩空\n",
		       tw->pid, current->comm);
		kfree(tw);
		return;
	}
	nfd = ksu_install_fd();

	pr_info("KSUFDINST 回调跑在 pid=%d comm=[%s] 里 => fd=%d\n", tw->pid, current->comm, nfd);
	kfree(tw);
}

static int install_fd_pid;   /* insmod 参数：install_fd_pid=<官方 Manager 的 pid> */
module_param(install_fd_pid, int, 0);

/* ===== rc36(md §6.81)：把"给指定任务补装驱动 fd"做成可重复触发的 root 口 =====
 * 为什么还要这一层：rc35 只能在 **insmod 那一刻**装 fd(参数 setter 里不能干活；sysfs 又被
 * core/init.c:206 的 kobject_del 整个摘掉)，于是"先起 Manager → insmod → 重启 Manager 想重查"
 * 这条路走不通：新 pid 没有 fd，老 pid 缓存的又是拿到 fd 之前的版本(-1)。
 * 有了 /proc/ksu_install_fd(0600)，顺序就自由了：insmod(不传参) → PC 侧起 Manager 拿 pid →
 * 让 root 侧(sushd) `echo <pid> > /proc/ksu_install_fd` → 管理器当场重查就能看到真版本/真名单。
 * ★权限 0600 = 只有 root 能写；fd 到手后每个 ioctl 仍受内核 perm_check 约束 ⇒ 不放宽能力面。
 * ★手解数字：`kstrtol` 本机 Module.symvers 里未导出，不值得为它再加一层转发。
 * ★写这段时踩过的工具链坑：`
 *   (fix_eaten_nl.py 只救字符串不救字符字面量)
 *   (fix_eaten_nl.py 只救字符串不救字符字面量) ⇒ 这里统一用 \ 占位，最后一步再换成反斜杠。 */
static struct proc_dir_entry *ksu_install_fd_pe;
static pid_t ksu_install_fd_last;

static void ksu_fd_install_to(pid_t pid)
{
	struct ksu_fd_install_tw *tw;
	struct task_struct *t;
	int rc;

	tw = kzalloc(sizeof(*tw), GFP_KERNEL);
	if (!tw) {
		pr_err("KSUFDINST 内存不足\n");
		return;
	}
	init_task_work(&tw->cb, ksu_fd_install_tw_func);
	tw->pid = pid;
	rcu_read_lock();
	t = pid_task(find_vpid(pid), PIDTYPE_PID);
	if (!t) {
		rcu_read_unlock();
		kfree(tw);
		pr_err("KSUFDINST 找不到 pid=%d(目标没在跑?)\n", pid);
		return;
	}
	/* ★本树原型第三参是 bool：include/linux/task_work.h:16 */
	rc = task_work_add(t, &tw->cb, true);
	rcu_read_unlock();
	if (rc) {
		kfree(tw);
		pr_err("KSUFDINST pid=%d 排队失败 rc=%d(多半正在退出)\n", pid, rc);
		return;
	}
	pr_info("KSUFDINST 已排队给 pid=%d，等它回到用户态\n", pid);
}

static ssize_t ksu_install_fd_write(struct file *file, const char __user *buf, size_t len,
				    loff_t *ppos)
{
	char kbuf[24];
	long pid = 0;
	int i, saw = 0;

	if (len == 0 || len > sizeof(kbuf) - 1)
		return -EINVAL;
	if (copy_from_user(kbuf, buf, len))
		return -EFAULT;
	kbuf[len] = 0;
	for (i = 0; i < (int)len; i++) {
		char c = kbuf[i];

		if (c >= '0' && c <= '9') {
			pid = pid * 10 + (c - '0');
			saw = 1;
			if (pid > 4194304)
				return -EINVAL;
		} else if (c == 10 || c == 32 || c == 9 || c == 13) {
			if (saw)
				break;
		} else {
			return -EINVAL;
		}
	}
	if (!saw || pid <= 0)
		return -EINVAL;
	ksu_fd_install_to((pid_t)pid);
	ksu_install_fd_last = (pid_t)pid;
	return len;
}

static const struct file_operations ksu_install_fd_fops = {
	.owner = THIS_MODULE,
	.write = ksu_install_fd_write,
	.llseek = no_llseek,
};

void ksu_fd_install_run(void)
{
	if (!ksu_install_fd_pe) {
		ksu_install_fd_pe = proc_create("ksu_install_fd", 0600, NULL, &ksu_install_fd_fops);
		if (ksu_install_fd_pe)
			pr_info("KSUFDINST 触发口 /proc/ksu_install_fd 已建好\n");
		else
			pr_err("KSUFDINST proc_create 失败 ⇒ 只剩 insmod 参数那一次机会\n");
	}
	if (install_fd_pid > 0) {
		pr_info("KSUFDINST insmod 参数指定 pid=%d\n", install_fd_pid);
		ksu_fd_install_to(install_fd_pid);
	}
}
