#ifdef __aarch64__

#include "../syscall_hook.h"

#include <linux/kallsyms.h>
#include <linux/mutex.h>
#include <asm/cacheflush.h>
#include "infra/symbol_resolver.h"
#include "../patch_memory.h"
#include "arch.h"
#include "klog.h" // IWYU pragma: keep

syscall_fn_t *ksu_syscall_table = NULL;
int ksu_dispatcher_nr = -1;

// Hook registration table — read with READ_ONCE from tracepoint/dispatcher
// context, written with WRITE_ONCE from init/exit context.
static ksu_syscall_hook_fn syscall_hooks[__NR_syscalls];

// Track all hooked syscall entries for restoration.
// Protected by hooked_entries_lock.
struct syscall_hook_entry {
    int nr;
    syscall_fn_t orig;
};

static DEFINE_MUTEX(hooked_entries_lock);
static struct syscall_hook_entry hooked_entries[16];
static int hooked_count = 0;

// Saved original syscall implementations for directly-patched entries.
// Handlers MUST call these instead of ksu_syscall_table[orig_nr], otherwise
// patching the slot would recurse into the trampoline.
syscall_fn_t ksu_orig_syscall_table[__NR_syscalls] __read_mostly;

static int patch_syscall_table(int nr, syscall_fn_t fn)
{
    if (ksu_syscall_table == NULL)
        return -ENOENT;
    if (nr < 0 || nr >= __NR_syscalls)
        return -EINVAL;

    pr_info("patch syscall %d, 0x%lx -> 0x%lx\n", nr, (unsigned long)READ_ONCE(ksu_syscall_table[nr]),
            (unsigned long)fn);

    int patch_rc = ksu_patch_text(&ksu_syscall_table[nr], &fn, sizeof(fn), KSU_PATCH_TEXT_FLUSH_DCACHE);
    if (patch_rc) {
        pr_err("patch syscall %d failed rc=%d\n", nr, patch_rc);
        return patch_rc;
    }
    pr_info("KSUBEAT A readback: slot=%d want=%px got=%px %s\n", nr, (void *)fn,
            (void *)READ_ONCE(ksu_syscall_table[nr]),
            (void *)ksu_syscall_table[nr] == (void *)fn ? "OK" : "MISMATCH");

    return 0;
}

// Direct syscall table patching: overwrite syscall_table[nr] with fn,
// save original to *old, and record for restoration at module exit.
void ksu_syscall_table_hook(int nr, syscall_fn_t fn, syscall_fn_t *old)
{
    if (ksu_syscall_table == NULL)
        return;
    if (nr < 0 || nr >= __NR_syscalls) {
        pr_info("invalid nr: %d\n", nr);
        return;
    }

    mutex_lock(&hooked_entries_lock);

    syscall_fn_t orig = READ_ONCE(ksu_syscall_table[nr]);
    if (old)
        *old = orig;
    ksu_orig_syscall_table[nr] = orig;

    // Record for later restoration
    int i;
    bool found = false;
    for (i = 0; i < hooked_count; i++) {
        if (hooked_entries[i].nr == nr) {
            found = true;
            break;
        }
    }
    if (!found) {
        if (hooked_count < ARRAY_SIZE(hooked_entries)) {
            hooked_entries[hooked_count].nr = nr;
            hooked_entries[hooked_count].orig = orig;
            hooked_count++;
        } else {
            pr_warn("hooked_entries full, cannot track syscall %d for restoration\n", nr);
        }
    }

    patch_syscall_table(nr, fn);

    mutex_unlock(&hooked_entries_lock);
}

// Restore syscall_table[nr] to its original value and remove from tracking list.
void ksu_syscall_table_unhook(int nr)
{
    int i;

    if (ksu_syscall_table == NULL)
        return;
    if (nr < 0 || nr >= __NR_syscalls)
        return;

    mutex_lock(&hooked_entries_lock);

    for (i = 0; i < hooked_count; i++) {
        if (hooked_entries[i].nr == nr) {
            patch_syscall_table(nr, hooked_entries[i].orig);
            // Remove entry by swapping with last
            hooked_entries[i] = hooked_entries[--hooked_count];
            mutex_unlock(&hooked_entries_lock);
            pr_info("unhooked syscall %d\n", nr);
            return;
        }
    }

    mutex_unlock(&hooked_entries_lock);
    pr_warn("syscall %d not found in hooked entries\n", nr);
}

static int __init ksu_find_ni_syscall_slots(int *out_slots, int max_slots)
{
    unsigned long ni_syscall;
    int i, count = 0;

    if (!ksu_syscall_table || max_slots <= 0)
        return 0;

    ni_syscall = (unsigned long)ksu_resolve_symbol_for_functable_hook("__arm64_sys_ni_syscall");

    pr_info("sys_ni_syscall: 0x%lx\n", ni_syscall);

    if (!ni_syscall)
        return 0;

    for (i = 0; i < __NR_syscalls && count < max_slots; i++) {
        if ((unsigned long)ksu_syscall_table[i] == ni_syscall) {
            out_slots[count++] = i;
            pr_info("ni_syscall %d: %d\n", count, i);
        }
    }

    return count;
}

// Unified dispatcher: reads original NR from x8, dispatches to handler.
// Validates that syscallno matches our dispatcher slot (i.e. we redirected it),
// otherwise it's a spurious call — return -ENOSYS.
static long __nocfi ksu_syscall_dispatcher(const struct pt_regs *regs)
{
    pr_info_once("KSUBEAT B dispatcher entered: syscallno=%d regs[8]=%d pid=%d comm=%s\n",
		 regs->syscallno, (int)PT_REGS_ORIG_SYSCALL(regs), current->pid, current->comm);
    if (regs->syscallno != ksu_dispatcher_nr) {
        pr_info("KSUBEAT E1: syscallno=%d != dispatcher_nr=%d\n",
                regs->syscallno, ksu_dispatcher_nr);
        return -ENOSYS;
    }

    /* rc80(§6.585)：调度器入口是所有钩子共用的热路径。旧版 pr_info_ratelimited 仍会每秒调用
     * ___ratelimit() 上千次；stat/faccessat 挂钩后热路径开销+限流计数把本机拖到 PS_HOLD 硬复位
     * (第 11 发死因，"14968/11025/10926 callbacks suppressed"=被限流量的累计)。⇒ 入口彻底静默，
     * 只保留下面 E1/E2/E3/E4 错误路径回执。想数调用次数请用 perf/ftrace/kprobe，别在热路径里 printk。 */
    int orig_nr = (int)PT_REGS_ORIG_SYSCALL(regs);


    if (regs->syscallno == orig_nr) {
        pr_info("KSUBEAT E2: regs[8] 取回的 orig_nr=%d 就是槽号(存档没生效) pid=%d\n",
                orig_nr, current->pid);
        return -ENOSYS;
    }

    // Restore registers to original state before dispatching
    ((struct pt_regs *)regs)->syscallno = orig_nr;
    PT_REGS_ORIG_SYSCALL((struct pt_regs *)regs) = orig_nr;

    if (likely(orig_nr >= 0 && orig_nr < __NR_syscalls)) {
        ksu_syscall_hook_fn fn = READ_ONCE(syscall_hooks[orig_nr]);
        if (likely(fn))
            return fn(orig_nr, regs);
    }

    /* ★原来是 `return -ENOSYS`：一条"没挂 hook 的号"被送进调度器就把那个系统调用打死。
     * 第十六发 adbd 全局 `exec /system/bin/sh failed: Function not implemented` 就是这个形状。
     * 改成回落原实现 ⇒ 最坏只是白跑一趟。 */
    if (orig_nr >= 0 && orig_nr < __NR_syscalls && ksu_syscall_table) {
        pr_info("KSUBEAT E3: orig_nr=%d 没挂 hook，回落原实现 pid=%d comm=%s\n",
                orig_nr, current->pid, current->comm);
        return ksu_orig_syscall_table[orig_nr](regs);
    }
    pr_info("KSUBEAT E4: orig_nr=%d 越界或 sys_call_table 没解析\n", orig_nr);
    return -ENOSYS;
}

// Shared trampoline installed at each hooked syscall table slot.
// Replaces the sys_enter tracepoint redirect (unavailable when
// CONFIG_FTRACE_SYSCALLS is not set). The kernel calls this directly with
// syscallno == the real nr; we stash the real nr, pretend we were redirected to
// the dispatcher, and let ksu_syscall_dispatcher route by nr.
static long __nocfi ksu_syscall_trampoline(const struct pt_regs *regs)
{
    struct pt_regs *r = (struct pt_regs *)regs;
    int orig_nr = r->syscallno;                 // real syscall number
    PT_REGS_ORIG_SYSCALL(r) = orig_nr;          // stash like the tracepoint did
    r->syscallno = ksu_dispatcher_nr;           // sentinel, matches dispatcher guard
    return ksu_syscall_dispatcher(regs);
}

// Register @fn for @nr AND patch the syscall table slot to the shared
// trampoline. This replaces the sys_enter tracepoint redirect (unavailable on
// kernels without CONFIG_FTRACE_SYSCALLS). The trampoline routes into
// ksu_syscall_dispatcher, which looks up @fn by @nr.
int ksu_install_syscall_hook(int nr, ksu_syscall_hook_fn fn)
{
    int rc = ksu_register_syscall_hook(nr, fn);
    if (rc)
        return rc;
    if (ksu_syscall_table)
        ksu_syscall_table_hook(nr, (syscall_fn_t)ksu_syscall_trampoline, NULL);
    return 0;
}

// Register a handler into the dispatcher's routing table.
// Does not modify the syscall table — the dispatcher slot is shared by all hooks.
int ksu_register_syscall_hook(int nr, ksu_syscall_hook_fn fn)
{
    if (nr < 0 || nr >= __NR_syscalls)
        return -EINVAL;
    if (READ_ONCE(syscall_hooks[nr])) {
        pr_warn("syscall hook for nr=%d already registered, skip\n", nr);
        return -EEXIST;
    }
    WRITE_ONCE(syscall_hooks[nr], fn);
    pr_info("registered syscall hook for nr=%d\n", nr);
    return 0;
}

// Remove a handler from the dispatcher's routing table.
// The syscall table is not touched — only the dispatcher stops routing this nr.
void ksu_unregister_syscall_hook(int nr)
{
    if (nr < 0 || nr >= __NR_syscalls)
        return;
    WRITE_ONCE(syscall_hooks[nr], NULL);
    pr_info("unregistered syscall hook for nr=%d\n", nr);
}

bool ksu_has_syscall_hook(int nr)
{
    if (nr < 0 || nr >= __NR_syscalls)
        return false;
    return READ_ONCE(syscall_hooks[nr]) != NULL;
}

void __init ksu_syscall_hook_init(void)
{
    if (!ksu_stage_ok(2)) { pr_info("KSUSTEP 2 skip: syscall_hook_init(sys_call_table+stop_machine)\n"); return; }

    memset(syscall_hooks, 0, sizeof(syscall_hooks));

    ksu_syscall_table = (syscall_fn_t *)ksu_resolve_symbol_for_functable_hook("sys_call_table");
    pr_info("sys_call_table=0x%lx", (unsigned long)ksu_syscall_table);

    if (!ksu_syscall_table)
        return;

    // No sys_enter tracepoint on this kernel (CONFIG_FTRACE_SYSCALLS is not set):
    // the dispatcher is reached only via the table-patched trampolines installed
    // per-hook in ksu_syscall_hook_manager_init. ksu_dispatcher_nr is a sentinel
    // (never a real syscall number) used by the trampoline to mark a dispatcher
    // call. The ni_syscall dispatcher-slot patch is intentionally dropped.
    ksu_dispatcher_nr = -1;
    pr_info("KSUBEAT S2b trampoline-based dispatch (no sys_enter tracepoint)\n");
}

void __exit ksu_syscall_hook_exit(void)
{
    int i;

    if (!ksu_syscall_table)
        goto clear_state;

    // First, restore all patched syscall table entries while the dispatcher
    // and hook table are still intact, so in-flight syscalls see valid state.
    mutex_lock(&hooked_entries_lock);
    for (i = 0; i < hooked_count; i++) {
        int nr = hooked_entries[i].nr;
        syscall_fn_t orig = hooked_entries[i].orig;

        pr_info("restore syscall %d to 0x%lx\n", nr, (unsigned long)orig);
        if (ksu_patch_text(&ksu_syscall_table[nr], &orig, sizeof(orig), KSU_PATCH_TEXT_FLUSH_DCACHE)) {
            pr_err("restore syscall %d failed\n", nr);
        }
    }
    hooked_count = 0;
    mutex_unlock(&hooked_entries_lock);

clear_state:
    // Now that the syscall table is restored, clear internal state.
    // At this point the tracepoint is already unregistered and synchronized
    // (done by ksu_syscall_hook_manager_exit before calling us), so no new
    // dispatches will occur.
    memset(syscall_hooks, 0, sizeof(syscall_hooks));
    ksu_dispatcher_nr = -1;

    pr_info("all syscall hooks restored\n");
}

#endif /* __aarch64__ */
