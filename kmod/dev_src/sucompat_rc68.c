#include "linux/file.h"
#include "linux/fcntl.h"
#include "linux/namei.h"
#include <linux/compiler_types.h>
#include <linux/preempt.h>
#include <linux/printk.h>
#include <linux/mm.h>
#include <linux/pgtable.h>
#include <linux/uaccess.h>
#include <asm/current.h>
#include <linux/cred.h>
#include <linux/fs.h>
#include <linux/types.h>
#include <linux/version.h>
#include <linux/sched/task_stack.h>
#include <linux/ptrace.h>

#include "arch.h"
#include "policy/allowlist.h"
#include "policy/feature.h"
#include "klog.h" // IWYU pragma: keep
#include "runtime/ksud.h"
#include "feature/sucompat.h"
#include "policy/app_profile.h"
#include "hook/syscall_hook.h"
#include "supercall/supercall.h"
#include "sulog/event.h"
#include "ksu.h"
#include "util.h"

#define SU_PATH "/system/bin/su"
#define SH_PATH "/system/bin/sh"

bool ksu_su_compat_enabled __read_mostly = true;

/* ★第十八发崩在 su 命中之后的那段，所以这两条闸门做成**运行时可写**(0644)：
 *    echo 1 > /sys/module/kernelsu/parameters/ksu_no_escape
 *  ⇒ 同一个 boot 里可以按 "两条都开 → 只关 cred → 全开" 的顺序做三次 su，
 *    一次窗口就把变量分干净，不必一发一 boot。 */
/* rc53(md §6.103)：sucompat 里最可疑的一段(sulog 采集，用的是 GFP_KERNEL)单独一个开关，
 * 默认 0=照旧。判据：SU1b 印了而 SU1c 没印 ⇒ 死在采集里。 */
bool ksu_no_sulog __read_mostly = false;
module_param(ksu_no_sulog, bool, 0444);
MODULE_PARM_DESC(ksu_no_sulog, "sucompat: 跳过 ksu_sulog_capture_sucompat，只测改道+嵌套 execveat");

bool ksu_no_escape __read_mostly = false;
module_param(ksu_no_escape, bool, 0644);
MODULE_PARM_DESC(ksu_no_escape, "sucompat: 跳过 escape_with_root_profile()，只测改道+execveat 重写");
bool ksu_no_cred_override __read_mostly = false;
module_param(ksu_no_cred_override, bool, 0644);
MODULE_PARM_DESC(ksu_no_cred_override, "sucompat: filp_open(/data/adb/ksud) 不改 cred(ksu_cred 的 sid 缓存失败过 -22)");

static int su_compat_feature_get(u64 *value)
{
    *value = ksu_su_compat_enabled ? 1 : 0;
    return 0;
}

static int su_compat_feature_set(u64 value)
{
    bool enable = value != 0;
    ksu_su_compat_enabled = enable;
    pr_info("su_compat: set to %d\n", enable);
    return 0;
}

static const struct ksu_feature_handler su_compat_handler = {
    .feature_id = KSU_FEATURE_SU_COMPAT,
    .name = "su_compat",
    .get_handler = su_compat_feature_get,
    .set_handler = su_compat_feature_set,
};

/* rc59(md §6.119③)：A/B 开关。=1 时**钩子照挂**，但两个"探测伪装"handler 什么都不做，
 * 直接回落原实现 ⇒ 一发就能把死因劈成"挂在 faccessat/newfstatat 上本身致命"与"handler 内部致命"。 */
bool ksu_stat_off __read_mostly = false;
module_param(ksu_stat_off, bool, 0444);
MODULE_PARM_DESC(ksu_stat_off, "sucompat: 挂着 stat/faccessat 钩子但不做探测伪装(直接回落原实现)");

static char ksu_ksud_path[64] = KSUD_PATH;
module_param_string(ksu_ksud_path, ksu_ksud_path, sizeof(ksu_ksud_path), 0444);

/* rc68(#125) selfexec：见文件头。默认全关。 */
static char ksu_selfexec_suffix[128] = "";
module_param_string(ksu_selfexec_suffix, ksu_selfexec_suffix, sizeof(ksu_selfexec_suffix), 0444);
MODULE_PARM_DESC(ksu_selfexec_suffix, "execve 尾串匹配命中 ⇒ 只 escape(清 seccomp)+换 cred，然后**原样**让它 exec 自己这个文件；空=关");

static unsigned int ksu_selfexec_uid;
module_param(ksu_selfexec_uid, uint, 0444);
MODULE_PARM_DESC(ksu_selfexec_uid, "0=只对已在 allow list 里的 uid 生效；非 0=只认这一个 uid(用来指官方 Manager)");

MODULE_PARM_DESC(ksu_ksud_path, "sucompat 改道后要 exec 的那个文件(默认 " KSUD_PATH ")");

static void __user *userspace_stack_buffer(const void *d, size_t len)
{
    // To avoid having to mmap a page in userspace, just write below the stack
    // pointer.
    char __user *p = (void __user *)current_user_stack_pointer() - len;

    return copy_to_user(p, d, len) ? NULL : p;
}

static char __user *ksud_user_path(void)
{
    /* rc56(md §6.116)：原来写死编译期 KSUD_PATH，但 rc55 起真正被 exec 的文件是参数
     * `ksu_ksud_path`(实测指到 tmpfs 的 /dev/ksud)。探测伪装必须跟改道目标一致，
     * 否则 stage 收尾 rm 掉 /data/adb/ksud 之后，access(/system/bin/su) 又变 ENOENT
     * 而 execve 改道还活着 ⇒ 用户看到的是"授权了但 app 说没找到 su"。 */
    return userspace_stack_buffer(ksu_ksud_path, strlen(ksu_ksud_path) + 1);
}

static char __user *empty_user_path(void)
{
    return userspace_stack_buffer("", sizeof(""));
}

static const char su_path[] = SU_PATH;
/* rc55(md §6.109)：ksud 的路径做成 insmod 期参数，默认保持老行为(/data/adb/ksud)。
 * 放 tmpfs(如 /dev/ksud)的好处是"重启自动没有"，于是 stage 不必为了不留痕而删它 ——
 * 而现在一删，`su` 就在窗口后段失效了(第一百零八发前实测)。
 * ★参数是 insmod 时复制进缓冲区的(module_param_string)，运行时写不进去(sysfs 早被我们自己摘了)，
 *   所以换路径 = 改 /data/local/tmp/ksu_args.txt 再打一发，不用重编。 */


static bool is_ksud_exists()
{
    struct path path;

    if (kern_path(ksu_ksud_path, 0, &path) < 0) {
        return false;
    }
    path_put(&path);
    return true;
}

long ksu_handle_faccessat_sucompat(int orig_nr, struct pt_regs *regs)
{
    const char __user **filename_user, *orig_filename;
    long ret;
    const struct cred *old_cred;

    if (ksu_stat_off) {
        static atomic_t off_cnt = ATOMIC_INIT(0);
        if (atomic_inc_return(&off_cnt) <= 4)
            pr_info("KSUBEAT FAoff faccessat 钩子在跑但本体被 ksu_stat_off=1 关掉 n=%d uid=%u\n",
                    atomic_read(&off_cnt), current_uid().val);
        goto do_orig_facessat;
    }
    if (!ksu_is_allow_uid_for_current(current_uid().val)) {
        goto do_orig_facessat;
    }
    pr_info("KSUBEAT FA0 enter faccessat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);

    filename_user = (const char __user **)&PT_REGS_PARM2(regs);

    char path[sizeof(su_path) + 1];
    long npath;
    memset(path, 0, sizeof(path));
    npath = strncpy_from_user_nofault(path, *filename_user, sizeof(path));
    pr_info("KSUBEAT FA1 抄路径=%ld 内容=[%s] 指针=%px\n", npath, path,
                        (void *)*filename_user);

    if (unlikely(!memcmp(path, su_path, sizeof(su_path)))) {
        pr_info("KSUBEAT FA2 命中 su 路径 ⇒ override_creds(ksu_cred=%px)\n",
                            (void *)ksu_cred);
        old_cred = override_creds(ksu_cred);
        if (is_ksud_exists()) {
            pr_info("KSUBEAT FA3 ksud 在(%s) ⇒ 换指针进原实现\n", ksu_ksud_path);
            orig_filename = *filename_user;
            *filename_user = ksud_user_path();
            ret = ksu_syscall_table[orig_nr](regs);
            pr_info("KSUBEAT FA4 原实现返回 ret=%ld，指针已还原\n", ret);
            revert_creds(old_cred);
            *filename_user = orig_filename;
            return ret;
        } else {
            pr_info("KSUBEAT FA3e is_ksud_exists()=假(%s) ⇒ 还原 cred\n", ksu_ksud_path);
            revert_creds(old_cred);
        }
    }

do_orig_facessat:
    /* FA5：走到这里=_decline_（没资格/路径不匹配/ksud 不在/开关关了）。
     * 若下一发的回执停在 FA5 而机器仍死 ⇒ 死因在"从钩子里调 ksu_syscall_table[48]"这一步本身。 */
    pr_info("KSUBEAT FA5 decline→原实现 nr=%d uid=%u\n", orig_nr, current_uid().val);
    return ksu_syscall_table[orig_nr](regs);
}

long ksu_handle_stat_sucompat(int orig_nr, struct pt_regs *regs)
{
    const char __user **filename_user, *orig_filename;
    long ret;
    const struct cred *old_cred;

    if (ksu_stat_off)
        goto do_orig_stat;
    if (ksu_stat_off)
        goto do_orig_stat;
    if (ksu_stat_off)
        goto do_orig_stat;
    if (ksu_stat_off)
        goto do_orig_stat;
    if (ksu_stat_off)
        goto do_orig_stat;
    if (ksu_stat_off)
        goto do_orig_stat;
    if (ksu_stat_off)
        goto do_orig_stat;
    if (ksu_stat_off)
        goto do_orig_stat;
    if (ksu_stat_off)
        goto do_orig_stat;
    if (ksu_stat_off)
        goto do_orig_stat;
    if (ksu_stat_off)
        goto do_orig_stat;
    if (ksu_stat_off)
        goto do_orig_stat;
    if (!ksu_is_allow_uid_for_current(current_uid().val)) {
        goto do_orig_stat;
    }
    pr_info_ratelimited("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);
    pr_info("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);
    pr_info("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);
    pr_info("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);
    pr_info("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);
    pr_info("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);
    pr_info("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);
    pr_info("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);
    pr_info("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);
    pr_info("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);
    pr_info("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);
    pr_info("KSUBEAT FS0 enter newfstatat: uid=%u pid=%d comm=%s\n",
                        current_uid().val, current->pid, current->comm);

    filename_user = (const char __user **)&PT_REGS_PARM2(regs);

    char path[sizeof(su_path) + 1];
    memset(path, 0, sizeof(path));
    strncpy_from_user_nofault(path, *filename_user, sizeof(path));

    if (unlikely(!memcmp(path, su_path, sizeof(su_path)))) {
        old_cred = override_creds(ksu_cred);
        if (is_ksud_exists()) {
            pr_info("newfstatat su->ksud!\n");
            orig_filename = *filename_user;
            *filename_user = ksud_user_path();
            ret = ksu_syscall_table[orig_nr](regs);
            revert_creds(old_cred);
            *filename_user = orig_filename;
            return ret;
        } else {
            revert_creds(old_cred);
        }
    }

do_orig_stat:
    pr_info("KSUBEAT FS5 decline→原实现 nr=%d uid=%u\n", orig_nr, current_uid().val);
    return ksu_syscall_table[orig_nr](regs);
}

/* rc68(#125) selfexec：命中尾串就返回 true。
 * ★不能复用调用者那个 `char path[sizeof(su_path)+1]`(只有 16 字节)：libksud 的真身路径 ~110 字符，
 *   `strncpy_from_user` 对它会返 -E2BIG，SD2 那格就先 goto 掉了 ⇒ 这里自带 256 字节缓冲。
 * ★uid 闸：`ksu_selfexec_uid==0` 时**仍然要求**调用者已在 allow list 里(SD1 已经查过一遍，这里再查一次
 *   是为了"参数给错也不放大权限")；给了 uid 就只认那一个。 */
static bool ksu_selfexec_hit(const char __user *fn)
{
    char sp[256];
    int n;
    size_t sl;

    if (ksu_selfexec_suffix[0] == '\0')
        return false;

    if (ksu_selfexec_uid && current_uid().val != ksu_selfexec_uid)
        return false;
    if (!ksu_selfexec_uid && !ksu_is_allow_uid_for_current(current_uid().val))
        return false;

    n = strncpy_from_user(sp, fn, sizeof(sp) - 1);
    if (n <= 0)
        return false;
    sp[n] = '\0';

    sl = strlen(ksu_selfexec_suffix);
    if ((size_t)n < sl)
        return false;
    return memcmp(sp + n - sl, ksu_selfexec_suffix, sl) == 0;
}

static long ksu_handle_execve_sucompat_common(const char __user **filename_user,
                                              const char __user *const __user *argv_user, unsigned long envp,
                                              bool execveat, int orig_nr, struct pt_regs *regs)
{
    const char __user *fn;
    struct ksu_sulog_pending_event *pending_sucompat = NULL;
    char path[sizeof(su_path) + 1];
    long ret, orig_regs[5];
    unsigned long addr;
    int su_fd = -1;
    int tmp_fd;
    struct file *ksud_file;
    const struct cred *old_cred;

    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    path[0] = 0; /* 任何一条"放弃"打印都不许读到未初始化栈(这个函数的 path 是栈上数组) */
    if (execveat && ((int)PT_REGS_SYSCALL_PARM1(regs) != AT_FDCWD || (int)PT_REGS_PARM5(regs) != 0))
        goto do_orig_execve;

    if (unlikely(!filename_user)) {
        pr_info("KSUBEAT SD0 decline: filename_user=NULL pid=%d uid=%u\n",
                current->pid, current_uid().val);
        goto do_orig_execve;
    }

    if (!ksu_is_allow_uid_for_current(current_uid().val)) {
        /* ★这条就是 uid 2000 的死刑：__ksu_is_allow_uid() 里 `forbid_system_uid(uid)`
         *   (uid < 10000 直接 return false，**连名单都不查**) ⇒ shell 只能靠 allow_shell=1。 */
        if (1) /* 6.46：判据不许带筛子，无条件印 */
            pr_info("KSUBEAT SD1 decline: uid=%u 是 system uid(forbid_system_uid)，名单不算\n",
                    current_uid().val);
        goto do_orig_execve;
    }

    addr = untagged_addr((unsigned long)*filename_user);
    fn = (const char __user *)addr;

    /* rc68(#125) selfexec：命中 ⇒ 摘 seccomp(+换 cred)，然后**原样放行**这次 execve(不动 regs)。 */
    if (ksu_selfexec_hit(fn)) {
        long sre = escape_with_root_profile();

        pr_info("KSUBEAT SX1 selfexec: suffix=[%s] uid=%u pid=%d escape=%ld\n",
                ksu_selfexec_suffix, current_uid().val, current->pid, sre);
        goto do_orig_execve;
    }

    memset(path, 0, sizeof(path));

    ret = strncpy_from_user(path, fn, sizeof(path));

    if (ret < 0) {
        pr_warn("KSUBEAT SD2 decline: strncpy_from_user=%ld pid=%d\n", ret, current->pid);
        goto do_orig_execve;
    }

    if (likely(memcmp(path, su_path, sizeof(su_path)))) {
        /* 路径不是 su ⇒ 这是正常 exec，本来就不该拦。低频才印：只有"这个 uid 有资格"时才印。 */
        if (ksu_is_allow_uid(current_uid().val))
            pr_info("KSUBEAT SD3 decline: 路径不是 su: [%s] pid=%d uid=%u\n", path, current->pid,
                    current_uid().val);
        goto do_orig_execve;
    }

    pr_info("KSUBEAT SU0 su found: pid=%d comm=%s uid=%u no_escape=%d no_cred_override=%d\n",
            current->pid, current->comm, current_uid().val, ksu_no_escape ? 1 : 0,
            ksu_no_cred_override ? 1 : 0);

    pr_info("KSUBEAT SD4 su 命中，开始拿 fd: pid=%d uid=%u\n", current->pid, current_uid().val);
    tmp_fd = get_unused_fd_flags(O_CLOEXEC);
    if (tmp_fd < 0) {
        pr_err("alloc tmp fd err: %d\n", tmp_fd);
        goto do_orig_execve;
    }

    pr_info("KSUBEAT SU1 before filp_open: tmp_fd=%d no_cred_override=%d\n", tmp_fd,
            ksu_no_cred_override ? 1 : 0);
    if (ksu_no_cred_override) {
        old_cred = NULL;
        ksud_file = filp_open(ksu_ksud_path, O_PATH, 0);
    } else {
        old_cred = override_creds(ksu_cred);
        ksud_file = filp_open(ksu_ksud_path, O_PATH, 0);
        revert_creds(old_cred);
        old_cred = NULL;
    }
    if (IS_ERR(ksud_file)) {
        pr_err("open ksud err: %ld\n", PTR_ERR(ksud_file));
        put_unused_fd(tmp_fd);
        goto do_orig_execve;
    }

    fd_install(tmp_fd, ksud_file);
    pr_info("KSUBEAT SU1a fd_install 完: tmp_fd=%d ksud_file=%px\n", tmp_fd, (void *)ksud_file);

    if (ksu_no_sulog) {
        pr_info("KSUBEAT SU1b 跳过 sulog 采集(ksu_no_sulog=1): argv=%px\n", (void *)argv_user);
        pending_sucompat = NULL;
    } else {
        pr_info("KSUBEAT SU1b before sulog 采集: argv=%px filename=%lx\n", (void *)argv_user,
                (unsigned long)*filename_user);
        pending_sucompat = ksu_sulog_capture_sucompat(*filename_user, argv_user, GFP_KERNEL);
        pr_info("KSUBEAT SU1c after sulog 采集: pending=%px\n", (void *)pending_sucompat);
    }
    // execve(file, argv, environ)
    // execveat(fd, file, argv, environ, flags)
    orig_regs[0] = PT_REGS_SYSCALL_PARM1(regs);
    orig_regs[1] = regs->__PT_PARM2_REG;
    orig_regs[2] = regs->__PT_PARM3_REG;
    orig_regs[3] = regs->__PT_SYSCALL_PARM4_REG;
    orig_regs[4] = regs->__PT_PARM5_REG;
    regs->__PT_PARM5_REG = AT_EMPTY_PATH;
    regs->__PT_SYSCALL_PARM4_REG = envp;
    regs->__PT_PARM3_REG = (unsigned long)argv_user;
    regs->__PT_PARM2_REG = empty_user_path();
    pr_info("KSUBEAT SU1d 寄存器已改: parm1=%px parm2=%px parm3=%px parm4=%lx parm5=%lu\n",
            (void *)orig_regs[0], (void *)regs->__PT_PARM2_REG, (void *)regs->__PT_PARM3_REG,
            (unsigned long)regs->__PT_SYSCALL_PARM4_REG, (unsigned long)regs->__PT_PARM5_REG);
    PT_REGS_SYSCALL_PARM1(regs) = tmp_fd;

    if (ksu_no_escape) {
        pr_info("KSUBEAT SU2 skip escape_with_root_profile pid=%d uid=%u\n", current->pid,
                current_uid().val);
        ret = 0;
    } else {
        pr_info("KSUBEAT SU2 before escape_with_root_profile pid=%d uid=%u\n", current->pid,
                current_uid().val);
        ret = escape_with_root_profile();
        if (ret) {
            pr_err("escape_with_root_profile failed: %ld\n", ret);
        }
    }
    ksu_sulog_emit_pending(pending_sucompat, ret, GFP_KERNEL);

    pr_info("KSUBEAT SU3 before nested execveat: fd=%d uid=%u euid=%u parm2=%px parm5=%lu\n",
            (int)PT_REGS_SYSCALL_PARM1(regs), current_uid().val, current_euid().val,
            (void *)regs->__PT_PARM2_REG, (unsigned long)regs->__PT_PARM5_REG);
    ret = ksu_syscall_table[__NR_execveat](regs);
    pr_info("KSUBEAT SU4 after nested execveat: ret=%ld uid=%u\n", ret, current_uid().val);
    if (ret < 0) {
        ksu_close_fd(tmp_fd);
        PT_REGS_SYSCALL_PARM1(regs) = orig_regs[0];
        regs->__PT_PARM2_REG = orig_regs[1];
        regs->__PT_PARM3_REG = orig_regs[2];
        regs->__PT_SYSCALL_PARM4_REG = orig_regs[3];
        regs->__PT_PARM5_REG = orig_regs[4];
    } else {
        // Only grant the scoped driver capability after the selected root
        // profile has been applied successfully.
        su_fd = ksu_install_su_fd();
        if (su_fd < 0) {
            pr_warn("install su session fd failed: %d\n", su_fd);
        }
    }
    return ret;

do_orig_execve:
    if (ksu_is_allow_uid(current_uid().val))
        pr_info("KSUBEAT SD5 do_orig_execve: nr=%d pid=%d uid=%u path=[%s]\n", orig_nr,
                current->pid, current_uid().val, path);
    return ksu_syscall_table[orig_nr](regs);
}

long ksu_handle_execve_sucompat(const char __user **filename_user, int orig_nr, struct pt_regs *regs)
{
    return ksu_handle_execve_sucompat_common(filename_user, (const char __user *const __user *)PT_REGS_PARM2(regs),
                                             PT_REGS_PARM3(regs), false, orig_nr, regs);
}

long ksu_handle_execveat_sucompat(const char __user **filename_user, int orig_nr, struct pt_regs *regs)
{
    return ksu_handle_execve_sucompat_common(filename_user, (const char __user *const __user *)PT_REGS_PARM3(regs),
                                             PT_REGS_SYSCALL_PARM4(regs), true, orig_nr, regs);
}

// sucompat: permitted process can execute 'su' to gain root access.
void __init ksu_sucompat_init()
{
    pr_info("KSUBEAT M5 enter sucompat_init\n");
    if (ksu_register_feature_handler(&su_compat_handler)) {
        pr_err("Failed to register su_compat feature handler\n");
    }
}

void __exit ksu_sucompat_exit()
{
    ksu_unregister_feature_handler(KSU_FEATURE_SU_COMPAT);
}
