/* abi_check2.c —— 设备实测偏移的**全表**编译期硬断言（路线 B 的第一道离闸门）
 *
 * 与 abi_check.c 的区别：那张表只有 4 条(module)+3 条(kprobe)，这张把
 * `kmod/device_offsets.txt` 里**每一条一手实测值**都编成断言 —— 全绿才说明
 * "打了布局补丁的构建树"真的复现了设备的内存图。
 *
 * 断言形式：**负长度数组 typedef**（`BUILD_BUG_ON` 在 clang 下会被忽略，2026-09-30 实测踩过）。
 * 失败时编译器会点名是哪个 chk_ 挂了，不掩盖也不假阳。
 *
 * 构建：见 kmod/remote_ksubuild.sh（补丁器 kmod/patch_device_layout.py 先跑）。
 */
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/sched.h>
#include <linux/sched/clock.h>
#include <linux/cred.h>
#include <linux/nsproxy.h>
#include <linux/stddef.h>
#include <linux/err.h>

#define CHK(name, cond) typedef char __chk_##name[(cond) ? 1 : -1]

/* ---- struct thread_info：设备 0x60 字节，canary 在 +0x50（mrs SP_EL0 直方图 5194 次）---- */
CHK(ti_size,   sizeof(struct thread_info) == 0x60);
CHK(ti_flags,  offsetof(struct thread_info, flags) == 0x00);
CHK(ti_canary, offsetof(struct thread_info, stack_canary) == 0x50);

/* ---- struct task_struct：头部 δ=+56(ti)、尾部 δ=+64 的全部 29 条实测锚点 ---- */
CHK(ts_state,          offsetof(struct task_struct, state) == 0x60);
CHK(ts_stack,          offsetof(struct task_struct, stack) == 0x68);
CHK(ts_usage,          offsetof(struct task_struct, usage) == 0x70);
CHK(ts_flags,          offsetof(struct task_struct, flags) == 0x74);
CHK(ts_ptrace,         offsetof(struct task_struct, ptrace) == 0x78);
CHK(ts_wake_entry,     offsetof(struct task_struct, wake_entry) == 0x80);
CHK(ts_prio,           offsetof(struct task_struct, prio) == 0xb4);
CHK(ts_static_prio,    offsetof(struct task_struct, static_prio) == 0xb8);
CHK(ts_normal_prio,    offsetof(struct task_struct, normal_prio) == 0xbc);
CHK(ts_dl_deadline,    (offsetof(struct task_struct, dl)
                        + offsetof(struct sched_dl_entity, deadline)) == 0x468);
CHK(ts_sched_tg,       offsetof(struct task_struct, sched_task_group) == 0x418);
CHK(ts_active_mm,      offsetof(struct task_struct, active_mm) == 0x5e8);
CHK(ts_restart_block,  offsetof(struct task_struct, restart_block) == 0x660);
/* ★标签按设备实测(real_parent 在 parent 之前)；__arm64_sys_getppid 读 0x6a0 是独立佐证 */
CHK(ts_real_parent,    offsetof(struct task_struct, real_parent) == 0x6a0);
CHK(ts_parent,         offsetof(struct task_struct, parent) == 0x6a8);
CHK(ts_children,       offsetof(struct task_struct, children) == 0x6b0);
CHK(ts_sibling,        offsetof(struct task_struct, sibling) == 0x6c0);
CHK(ts_group_leader,   offsetof(struct task_struct, group_leader) == 0x6d0);
CHK(ts_thread_pid,     offsetof(struct task_struct, thread_pid) == 0x6f8);
CHK(ts_real_cred,      offsetof(struct task_struct, real_cred) == 0x840);
CHK(ts_cred,           offsetof(struct task_struct, cred) == 0x848);
CHK(ts_fs,             offsetof(struct task_struct, fs) == 0x870);
CHK(ts_files,          offsetof(struct task_struct, files) == 0x878);
CHK(ts_nsproxy,        offsetof(struct task_struct, nsproxy) == 0x880);
CHK(ts_signal,         offsetof(struct task_struct, signal) == 0x888);
CHK(ts_sighand,        offsetof(struct task_struct, sighand) == 0x890);
CHK(ts_pi_lock,        offsetof(struct task_struct, pi_lock) == 0x91c);
CHK(ts_pi_waiters,     offsetof(struct task_struct, pi_waiters) == 0x928);
CHK(ts_pi_top_task,    offsetof(struct task_struct, pi_top_task) == 0x938);
CHK(ts_pi_blocked_on,  offsetof(struct task_struct, pi_blocked_on) == 0x940);
/* KSU 实际用到的字段。★设备值 = 树值 + 64(尾部阶梯)；下面这四个数都再被 ti_scan 的
 * 直方图独立佐证过：mm 0x5e0(89 次, elf_core_dump) / pid 0x690(107 次) /
 * comm 0x858 / seccomp 0x8f8(3 次, __secure_computing+__seccomp_filter)。
 * 我第一版把 pid/comm/seccomp 写成了**树的值**(少加 64) ⇒ 被这道闸门当场咬住，这就是它存在的意义。 */
CHK(ts_ksu_mm,         offsetof(struct task_struct, mm) == 0x5e0);
CHK(ts_ksu_pid,        offsetof(struct task_struct, pid) == 0x690);
CHK(ts_ksu_comm,       offsetof(struct task_struct, comm) == 0x858);
CHK(ts_ksu_seccomp,    offsetof(struct task_struct, seccomp) == 0x8f8);

/* ---- struct cred：rela 三条 + 真机行为证据 ⇒ δ=0（不打补丁，树原样就该对）---- */
CHK(cr_usage,      offsetof(struct cred, usage) == 0);
CHK(cr_uid,        offsetof(struct cred, uid) == 4);
CHK(cr_gid,        offsetof(struct cred, gid) == 8);
CHK(cr_user,       offsetof(struct cred, user) == 128);
CHK(cr_user_ns,    offsetof(struct cred, user_ns) == 136);
CHK(cr_group_info, offsetof(struct cred, group_info) == 144);

/* ---- struct module：设备 960 / name@24 / init@392 / exit@888 ---- */
CHK(md_size,  sizeof(struct module) == 960);
CHK(md_name,  offsetof(struct module, name) == 24);
CHK(md_init,  offsetof(struct module, init) == 392);
CHK(md_exit,  offsetof(struct module, exit) == 888);

/* ---- struct kprobe：全部设备实测（register_kprobe rc=0 + 解析地址与离线 kallsyms 逐字节吻合）---- */
CHK(kp_size,   sizeof(struct kprobe) == 136);
CHK(kp_addr,   offsetof(struct kprobe, addr) == 40);
CHK(kp_sym,    offsetof(struct kprobe, symbol_name) == 48);
CHK(kp_pre,    offsetof(struct kprobe, pre_handler) == 64);
CHK(kp_post,   offsetof(struct kprobe, post_handler) == 72);
CHK(kp_opcode, offsetof(struct kprobe, opcode) == 88);

/* ---- 构建开关必须在（少一条就会让上面的布局整体错位）---- */
CHK(have_modules,  IS_ENABLED(CONFIG_MODULES));
CHK(have_kprobes,  IS_ENABLED(CONFIG_KPROBES));
CHK(have_modver,   IS_ENABLED(CONFIG_MODVERSIONS));
CHK(have_scs,      IS_ENABLED(CONFIG_SHADOW_CALL_STACK));

static int __init abi_check2_init(void) { return -EAGAIN; }   /* 从不上机：只要它编得过 */
static void __exit abi_check2_exit(void) {}
module_init(abi_check2_init);
module_exit(abi_check2_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("compile-time ABI match against on-device measured offsets (full table)");
