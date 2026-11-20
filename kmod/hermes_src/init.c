#include <linux/export.h>
#include <linux/fs.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/rcupdate.h>
#include <linux/sched.h>
#include <linux/workqueue.h>
#include <linux/moduleparam.h>

#include "policy/allowlist.h"
#include "policy/app_profile.h"
#include "policy/feature.h"
#include "klog.h" // IWYU pragma: keep
#include "manager/manager_observer.h"
#include "manager/throne_tracker.h"
#include "hook/syscall_hook_manager.h"
#include "hook/lsm_hook.h"
#include "runtime/ksud.h"
#include "runtime/ksud_boot.h"
#include "feature/sulog.h"
#include "supercall/supercall.h"
#include "ksu.h"
#include "infra/file_wrapper.h"
#include "selinux/selinux.h"
#include "hook/syscall_hook.h"
#include "feature/adb_root.h"
#include "feature/selinux_hide.h"
#include "infra/symbol_resolver.h"

#if defined(__x86_64__) && !defined(CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER)
#include <asm/cpufeature.h>
#include <linux/version.h>
#ifndef X86_FEATURE_INDIRECT_SAFE
#error "FATAL: Your kernel is missing the indirect syscall bypass patches!"
#endif
#endif

// workaround for A12-5.10 kernel
// Some third-party kernel (e.g. linegaeOS) uses wrong toolchain, which supports
// CC_HAVE_STACKPROTECTOR_SYSREG while gki's toolchain doesn't.
// Therefore, ksu lkm, which uses gki toolchain, requires this __stack_chk_guard,
// while those third-party kernel can't provide.
// Thus, we manually provide it instead of using kernel's
#if defined(CONFIG_STACKPROTECTOR) &&                                                                                  \
    (defined(CONFIG_ARM64) && defined(MODULE) && !defined(CONFIG_STACKPROTECTOR_PER_TASK))
#include <linux/stackprotector.h>
#include <linux/random.h>
unsigned long __stack_chk_guard __ro_after_init __attribute__((visibility("hidden")));

__attribute__((no_stack_protector)) void __init ksu_setup_stack_chk_guard()
{
    unsigned long canary;

    /* Try to get a semi random initial value. */
    get_random_bytes(&canary, sizeof(canary));
    canary ^= LINUX_VERSION_CODE;
    canary &= CANARY_MASK;
    __stack_chk_guard = canary;
}

__attribute__((naked)) int __init kernelsu_init_early(void)
{
    asm("mov x19, x30;\n"
        "bl ksu_setup_stack_chk_guard;\n"
        "mov x30, x19;\n"
        "b kernelsu_init;\n");
}
#define NEED_OWN_STACKPROTECTOR 1
#else
#define NEED_OWN_STACKPROTECTOR 0
#endif

struct cred *ksu_cred;
bool ksu_late_loaded;

#ifdef CONFIG_KSU_DEBUG
bool allow_shell = true;
#else
bool allow_shell = false;
#endif
module_param(allow_shell, bool, 0);

bool ksu_no_custom_rc = false;
module_param_named(norc, ksu_no_custom_rc, bool, 0);

#ifdef MODULE
bool ksu_bundled = false;
module_param_named(bundled, ksu_bundled, bool, 0);
#endif

int __init kernelsu_init(void)
{
#if defined(__x86_64__) && !defined(CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER)
    // If the kernel has the hardening patch, X86_FEATURE_INDIRECT_SAFE must be set
    if (!boot_cpu_has(X86_FEATURE_INDIRECT_SAFE)) {
        pr_alert("*************************************************************");
        pr_alert("**     NOTICE NOTICE NOTICE NOTICE NOTICE NOTICE NOTICE    **");
        pr_alert("**                                                         **");
        pr_alert("**        X86_FEATURE_INDIRECT_SAFE is not enabled!        **");
        pr_alert("**      KernelSU will abort initialization to prevent      **");
        pr_alert("**                     kernel panic.                       **");
        pr_alert("**                                                         **");
        pr_alert("**     NOTICE NOTICE NOTICE NOTICE NOTICE NOTICE NOTICE    **");
        pr_alert("*************************************************************");
        return -ENOSYS;
    }
#endif

#ifdef MODULE
    ksu_late_loaded = (current->pid != 1);
#else
    ksu_late_loaded = false;
#endif

#ifdef CONFIG_KSU_DEBUG
    pr_alert("*************************************************************");
    pr_alert("**     NOTICE NOTICE NOTICE NOTICE NOTICE NOTICE NOTICE    **");
    pr_alert("**                                                         **");
    pr_alert("**         You are running KernelSU in DEBUG mode          **");
    pr_alert("**                                                         **");
    pr_alert("**     NOTICE NOTICE NOTICE NOTICE NOTICE NOTICE NOTICE    **");
    pr_alert("*************************************************************");
#endif
    if (allow_shell) {
        pr_alert("shell is allowed at init!");
    }

ksu_dev_syms_init();   /* ★必须在最前面: KSU 自己的 resolver 会用到未导出符号(md §6.23) */
    ksu_cred = prepare_creds();
    if (!ksu_cred) {
        pr_err("prepare cred failed!\n");
        return -ENOSYS;
    }

    ksu_init_symbol_resolver();
    ksu_syscall_hook_init();

    ksu_feature_init();
    ksu_sulog_init();
    ksu_adb_root_init();
    ksu_lsm_hook_init();
    ksu_selinux_hide_init();

    ksu_supercalls_init();
    ksu_app_profile_init();

    if (ksu_late_loaded) {
        pr_info("late load mode, skipping kprobe hooks\n");


        pr_info("KSUBEAT L0 before apply_kernelsu_rules()\n");
    apply_kernelsu_rules();
        pr_info("KSUBEAT L1 before cache_sid()\n");
    cache_sid();
        pr_info("KSUBEAT L2 before setup_ksu_cred()\n");
    setup_ksu_cred();

        // Grant current process (ksud late-load) root
        // with KSU SELinux domain before enforcing SELinux, so it
        // can continue to access /data/app etc. after enforcement.
        pr_info("KSUBEAT L3 before escape_to_root_for_init()\n");
    escape_to_root_for_init();

        pr_info("KSUBEAT L4 before ksu_allowlist_init()\n");
    ksu_allowlist_init();
        pr_info("KSUBEAT L5 before ksu_load_allow_list()\n");
    ksu_load_allow_list();

        pr_info("KSUBEAT L6 before ksu_syscall_hook_manager_init()\n");
    ksu_syscall_hook_manager_init();

        pr_info("KSUBEAT L7 before ksu_throne_tracker_init()\n");
    ksu_throne_tracker_init();
        pr_info("KSUBEAT L8 before ksu_observer_init()\n");
    ksu_observer_init();
        pr_info("KSUBEAT L10 before ksu_file_wrapper_init()\n");
    ksu_file_wrapper_init();

        ksu_boot_completed = true;
        track_throne(false);

        if (!getenforce()) {
            pr_info("Permissive SELinux, enforcing\n");
            setenforce(true);
        }

    } else {
        ksu_syscall_hook_manager_init();

        ksu_allowlist_init();

        ksu_throne_tracker_init();

        ksu_ksud_init();

        ksu_file_wrapper_init();
    }

    /* killscan(§6.69)：扫厂商模块里所有 bl->force_sig，默认只打印。放 init 末尾：
     *   这时 KSU 自己的符号解析层已经热好了，走的是 kallsyms 而不是 kprobe ⇒ 不会跟
     *   insmod 的 module_mutex 抢锁序。 */
    { extern void ksu_killscan_run(void); ksu_killscan_run(); }
    /* rc35(md §6.80)：把驱动 fd 补装进 insmod 参数指定的任务(官方 Manager 只靠
     *   扫 /proc/self/fd 找 [ksu_driver]，native 层没有 reboot 超级调用)。 */
    { extern void ksu_fd_install_run(void); ksu_fd_install_run(); }

#ifdef MODULE
#ifndef CONFIG_KSU_DEBUG
    kobject_del(&THIS_MODULE->mkobj.kobj);
#endif
#endif
    return 0;
}

void __exit kernelsu_exit(void)
{
    // Phase 1: Stop all hooks first to prevent new callbacks
    ksu_syscall_hook_manager_exit();

    ksu_supercalls_exit();

    if (!ksu_late_loaded)
        ksu_ksud_exit();

    // Wait for any in-flight RCU readers (e.g. handler traversing allow_list)
    synchronize_rcu();

    // Phase 2: Now safe to release data structures
    ksu_observer_exit();

    ksu_throne_tracker_exit();

    ksu_allowlist_exit();

    ksu_selinux_hide_exit();
    ksu_lsm_hook_exit();
    ksu_adb_root_exit();
    ksu_sulog_exit();
    ksu_feature_exit();

    put_cred(ksu_cred);
}

#if NEED_OWN_STACKPROTECTOR
module_init(kernelsu_init_early);
#else
module_init(kernelsu_init);
#endif
module_exit(kernelsu_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("weishu");
MODULE_DESCRIPTION("Android KernelSU");
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
MODULE_IMPORT_NS("VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver");
#else
MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);
#endif
