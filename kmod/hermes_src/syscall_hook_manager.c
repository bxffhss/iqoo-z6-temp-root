#include "linux/printk.h"
#include <linux/spinlock.h>
#include <linux/kprobes.h>
#include <linux/tracepoint.h>
#include <asm/syscall.h>
#include <linux/ptrace.h>
#include <linux/atomic.h>
#include <linux/slab.h>
#include <trace/events/syscalls.h>

#include <linux/version.h>
#include <linux/sched/task_stack.h>
#include <linux/compat.h>

#include "arch.h"
#include "klog.h" // IWYU pragma: keep
#include "hook/syscall_hook_manager.h"
#include "hook/tp_marker.h"
#include "feature/sucompat.h"
#include "hook/setuid_hook.h"
#include "hook/syscall_hook.h"
#include "hook/syscall_event_bridge.h"
#if defined(__riscv)
#include "hook/riscv64/syscall_regs.h"
#endif

#ifdef CONFIG_KRETPROBES

static struct kretprobe *init_kretprobe(const char *name, kretprobe_handler_t handler)
{
    struct kretprobe *rp = kzalloc(sizeof(struct kretprobe), GFP_KERNEL);
    if (!rp)
        return NULL;
    rp->kp.symbol_name = name;
    rp->handler = handler;
    rp->data_size = 0;
    rp->maxactive = 0;

    int ret = register_kretprobe(rp);
    pr_info("hook_manager: register_%s kretprobe: %d\n", name, ret);
    if (ret) {
        kfree(rp);
        return NULL;
    }

    return rp;
}

static void destroy_kretprobe(struct kretprobe **rp_ptr)
{
    struct kretprobe *rp = *rp_ptr;
    if (!rp)
        return;
    unregister_kretprobe(rp);
    synchronize_rcu();
    kfree(rp);
    *rp_ptr = NULL;
}

static int syscall_regfunc_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    unsigned long flags;
    ksu_tp_marker_lock(&flags);
    if (ksu_tp_marker_reg_count() < 1) {
        // while install our tracepoint, mark our processes
        ksu_mark_running_process_locked();
    } else if (ksu_tp_marker_reg_count() == 1) {
        // while other tracepoint first added, mark all processes
        ksu_mark_all_process();
    }
    ksu_tp_marker_inc_reg_count();
    ksu_tp_marker_unlock(&flags);
    return 0;
}

static int syscall_unregfunc_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    unsigned long flags;
    ksu_tp_marker_lock(&flags);
    ksu_tp_marker_dec_reg_count();
    if (ksu_tp_marker_reg_count() <= 0) {
        // while no tracepoint left, unmark all processes
        ksu_unmark_all_process();
    } else if (ksu_tp_marker_reg_count() == 1) {
        // while just our tracepoint left, unmark disallowed processes
        ksu_mark_running_process_locked();
    }
    ksu_tp_marker_unlock(&flags);
    return 0;
}

static struct kretprobe *syscall_regfunc_rp = NULL;
static struct kretprobe *syscall_unregfunc_rp = NULL;
#endif

#ifdef CONFIG_HAVE_SYSCALL_TRACEPOINTS
static atomic_t ksu_tp_fired = ATOMIC_INIT(0);
/* rc54(md §6.104)：KSUBEAT F 回执的密度开关。1=只在改道在即印(默认)，2=老行为(每次 execve 都印)，
 * 0=只在头四次开火时印。判死因要靠这些回执，洪印会把它们从活落盘里挤掉。 */
int ksu_trace_print __read_mostly = 3;   /* rc58：默认只印 execve 家族(见上面注释) */
module_param(ksu_trace_print, int, 0444);
MODULE_PARM_DESC(ksu_trace_print, "KSUBEAT F 回执密度: 0=四次开火, 1=只在改道在即, 2=每次 execve/execveat");

// sys_enter handler: redirect hooked syscalls to the dispatcher
/* rc74b(md 6.414)：出生即装的状态在 infra/dev_syms.c 里(那把文件才是驱动 fd 的家)。
 * 这里只声明两个符号，不动任何头文件。 */
extern int ksu_mgr_birth_fd;
extern void ksu_mgr_birth_check(void);

static void ksu_sys_enter_handler(void *data, struct pt_regs *regs, long id)
{
#if defined(__x86_64__)
    if (unlikely(in_compat_syscall()))
#elif defined(__aarch64__) || defined(__riscv)
    if (unlikely(is_compat_task()))
#endif
        return;

    if (ksu_dispatcher_nr < 0)
        return;

    /* rc74b(md 6.414)：Manager 出生即装 fd(现在一个进程只排一次，且只认主进程)。
     * 见 infra/dev_syms.c 的 ksu_mgr_birth_check()。放在 dispatcher 早退之后：
     * 它必须比这块屏自己那次一次性查询早，而这条 tracepoint 是全机每条 syscall 都过的地方。
     * 谓词里不许睡眠(此处在 preempt-disabled 的 probe 里)，分配只有 GFP_ATOMIC。 */
    if (unlikely(ksu_mgr_birth_fd))
        ksu_mgr_birth_check();

    {
        int nfired = atomic_inc_return(&ksu_tp_fired);
        /* rc54(md §6.104)：老口径"每次 execve/execveat 都印"在本机是每秒几十行的洪印，
         * 会把环形缓冲刷爆 ⇒ 活落盘(dd 逐块)整段丢回执，而我判死因靠的就是这些回执。
         * 默认(1)只在"真的要改道的那一刻"印：execve/execveat 且这个号挂了钩子。 */
        int want = 0;
        if (ksu_trace_print == 2)
            want = (nfired <= 8 || id == __NR_execve || id == __NR_execveat);
        else if (ksu_trace_print == 1)
            want = ksu_has_syscall_hook(id);
        else if (ksu_trace_print == 3)
            /* rc58 默认：只印"改道在即"那三个号。stat/faccessat 挂了钩之后是全机每秒几百次的
             * 热路径，按号印会把 syscall 入口刷死(§6.118 的整机复位就是这么来的)。 */
            want = ksu_has_syscall_hook(id) &&
                   (id == __NR_execve || id == __NR_execveat || id == __NR_setresuid);
        else
            want = (nfired <= 4);
        if (want)
            pr_info("KSUBEAT F sys_enter fired#%d: id=%ld dispatcher_nr=%d has_hook=%d "
                    "pid=%d comm=%s ti_flags=%#lx\n",
                    nfired, id, ksu_dispatcher_nr, ksu_has_syscall_hook(id) ? 1 : 0,
                    current->pid, current->comm, current_thread_info()->flags);
    }

    if (ksu_has_syscall_hook(id)) {
        struct pt_regs *current_regs = task_pt_regs(current);

#if defined(__x86_64__)
        // Stash the original syscall number in ax.
        // We use ax because it currently just holds -ENOSYS and is safe to overwrite.
        current_regs->ax = id;
        current_regs->orig_ax = ksu_dispatcher_nr;
#elif defined(__aarch64__)
        PT_REGS_ORIG_SYSCALL(current_regs) = id;
        current_regs->syscallno = ksu_dispatcher_nr;
        /* rc58(§6.118)：这条原来是"只要重定向就印" ⇒ 挂了 stat/faccessat 钩之后是全机热路径。
         * 按号收口：只有 execve 家族才印。 */
        if (id == __NR_execve || id == __NR_execveat)
            pr_info("KSUBEAT F2 redirect: id=%ld -> %d x8_stash=%#llx pid=%d\n",
                    id, ksu_dispatcher_nr,
                    (unsigned long long)PT_REGS_ORIG_SYSCALL(current_regs), current->pid);
#elif defined(__riscv)
        /* orig_a0 retains argument zero; a0 is the -ENOSYS return slot. */
        ksu_riscv_redirect_syscall(current_regs, id, ksu_dispatcher_nr);
#endif
    }
}
#endif

void __init ksu_syscall_hook_manager_init(void)
{
    if (!ksu_stage_ok(7)) { pr_info("KSUSTEP 7 skip: hook_manager(tracepoint+setuid+sucompat)\n"); return; }
    pr_info("hook_manager: ksu_hook_manager_init called\n");

#ifdef CONFIG_KRETPROBES
    syscall_regfunc_rp = init_kretprobe("syscall_regfunc", syscall_regfunc_handler);
    syscall_unregfunc_rp = init_kretprobe("syscall_unregfunc", syscall_unregfunc_handler);
#endif

    // Register syscall hooks via dispatcher
    if (ksu_hook_mask & (1U << 0)) { ksu_install_syscall_hook(__NR_setresuid, ksu_hook_setresuid); }
    if (ksu_hook_mask & (1U << 1)) { ksu_install_syscall_hook(__NR_execve, ksu_hook_execve); }
    if (ksu_hook_mask & (1U << 2)) { ksu_install_syscall_hook(__NR_execveat, ksu_hook_execveat); }
    if (ksu_hook_mask & (1U << 3)) { ksu_install_syscall_hook(__NR_newfstatat, ksu_hook_newfstatat); }
    if (ksu_hook_mask & (1U << 4)) { ksu_install_syscall_hook(__NR_faccessat, ksu_hook_faccessat); }

    pr_info("KSUBEAT M2 trampoline-based redirect installed (no sys_enter tracepoint)\n");

    pr_info("KSUBEAT M3 before setuid_hook_init/sucompat_init\n");
    ksu_setuid_hook_init();
    ksu_sucompat_init();
}

void __exit ksu_syscall_hook_manager_exit(void)
{
    if (!ksu_stage_ok(7)) { pr_info("KSUSTEP 7 exit-skip\n"); return; }
    pr_info("hook_manager: ksu_hook_manager_exit called\n");
    pr_info("KSUBEAT F9 trampoline dispatch torn down\n");

#ifdef CONFIG_KRETPROBES
    destroy_kretprobe(&syscall_regfunc_rp);
    destroy_kretprobe(&syscall_unregfunc_rp);
#endif

    ksu_unregister_syscall_hook(__NR_setresuid);
    ksu_unregister_syscall_hook(__NR_execve);
    ksu_unregister_syscall_hook(__NR_execveat);
    ksu_unregister_syscall_hook(__NR_newfstatat);
    ksu_unregister_syscall_hook(__NR_faccessat);

    ksu_syscall_hook_exit();

    ksu_sucompat_exit();
    ksu_setuid_hook_exit();
}
