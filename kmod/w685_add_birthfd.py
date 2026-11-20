#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w685_add_birthfd.py —— 在构建机上把 rc74 那一小块代码打进树里：Manager 出生即装驱动 fd。
   跑法(在远端)：python3 /home/lucy/w685_add_birthfd.py /root/k/ksu/kernel
   起因(md §6.406/§6.407/§6.409/§6.411/§6.413)：
     官方 Manager 首页那块「支持/越狱模式」的牌子是**进程启动时一次性查询**(libkernelsu.so 扫 /proc/self/fd 找
     [ksu_driver])。fd 晚到刷不亮一个已经在跑的进程(§6.406 实测：fd 已在表里、只把它顶回前台⇒仍"不支持")，
     所以恢复只能连进程一起重来(§6.407 那条腿)。用户态 0.1s/1s 轮询都抢不过它自己那次查询(§6.405/§6.406)。
     ⇒ 唯一比它更早的位置在内核里：我们**自己已经注册了 sys_enter tracepoint**(本文件下游那个 handler)，
       每条 syscall 都经过它，比任何用户态节拍都早。
   形状(两个文件，只加不改)：
     1) infra/dev_syms.c 末尾追加：模块参数 ksu_mgr_birth_fd(**默认 1=开**，所以 ksu_args.txt 一个字都不用改)
        + ksu_mgr_birth_check()：谓词＝主线程 ∧ uid 命中 ksu_manager_appid ∧ 这个进程还没排过(pid+start_time 双键，
        防 pid 复用被误判成"已装过")，然后走现成的 task_work 链排队 ⇒ ksu_install_fd() 在**返回用户态之前**跑，
        因此抢在 Manager 自己那次查询前面。
     2) hook/syscall_hook_manager.c：在 sys_enter handler 里"dispatcher 已就绪"之后加一行谓词调用。
   ★三条不许碰的红线：
     · probe 里**不能睡**：tracepoint 回调在 preempt-disabled 下跑 ⇒ 分配一律 GFP_ATOMIC( GFP_KERNEL 会 sleep＝非法)。
     · 不引入新导出符号/不改 __versions ⇒ 装入门径逐字同 rc73(§6.412 那四条离线核对)。
     · 护栏(``!current->files``)留着——出生即装排的也是同一个回调。
   幂等：两份文件里已经有 KSUBIRTH 就跳过(并核 md5 只变了一次)。
"""
import hashlib
import io
import os
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
DS = os.path.join(M, "infra", "dev_syms.c")
SH = os.path.join(M, "hook", "syscall_hook_manager.c")
WANT_DS = "e0da5e8c12f32c7110eb74c8538198a0"     # rc73 那份(基线+唯一护栏)
WANT_SH = "8eb3e5990b3cf0ec85784821ce0b208a"     # rc73 树里那份


def md5(p):
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()


def rd(p):
    return io.open(p, encoding="utf-8", errors="surrogateescape").read()


def wr(p, s):
    io.open(p, "w", encoding="utf-8", newline="", errors="surrogateescape").write(s)


BLOCK = r"""

/* ===== rc74(md 6.413)：Manager 出生即装驱动 fd，见 hook/syscall_hook_manager.c 的调用点 =====
 * 为什么要它在内核里做：官方 Manager 首页那块牌子是**进程启动时一次性查询**(扫 /proc/self/fd 找
 * [ksu_driver]，md 6.406 一手)。fd 晚到刷不亮一个已经在跑的进程；用户态 0.1s/1s 节拍都抢不过
 * 它自己那次查询(md 6.405/6.406 判负，md 6.407 只能靠"连进程一起重启"恢复)。
 * sys_enter tracepoint(我们本来就注册了)在全机每条 syscall 上都在，比任何用户态轮询都早；
 * 而真正的安装仍然走现成那条 task_work 链(同一个回调、同一把 files==NULL 护栏)：
 * 排在他自己那次查询之前的任一 syscall 处，回调在返回用户态时跑完 => 赶得上。
 * 红线：probe 回调在 preempt-disabled 下运行 => 这里只许 GFP_ATOMIC，不许任何可能睡眠的分配。
 * ksu_mgr_birth_fd 默认 1(开)：这样出货的 ksu_args.txt 一个字都不改——五条参数是 §6.32x 那条
 * "装载期致死"轴上逐字定下来的，动它就是两个变量同时改，红了一发也说不出是谁造成的。
 * 要逐字退回 rc73 的形状：insmod 多带 ksu_mgr_birth_fd=0(只在实验里这么用，不改交付 args)。 */
int ksu_mgr_birth_fd = 1;
module_param(ksu_mgr_birth_fd, int, 0444);
MODULE_PARM_DESC(ksu_mgr_birth_fd, "1=install driver fd into the official Manager at its first syscall (0 = exactly rc73)");

static pid_t ksu_birth_pid;             /* last Manager main thread we queued for */
static unsigned long long ksu_birth_start;   /* paired with task->start_time: pid reuse must not look like "already done" */
static atomic_t ksu_birth_queued = ATOMIC_INIT(0);

static void ksu_fd_install_self_tw(void)
{
    struct ksu_fd_install_tw *tw;
    int rc;

    /* preempt-disabled context: GFP_ATOMIC only. Under memory pressure this just means
     * "no birth-install this round" - the /proc/ksu_install_fd port still works. */
    tw = kzalloc(sizeof(*tw), GFP_ATOMIC);
    if (!tw) {
        pr_err("KSUBIRTH kzalloc(ATOMIC) failed pid=%d - no birth fd this round\n", current->pid);
        return;
    }
    init_task_work(&tw->cb, ksu_fd_install_tw_func);
    tw->pid = current->pid;
    /* this tree's task_work_add() takes a bool (include/linux/task_work.h) */
    rc = task_work_add(current, &tw->cb, true);
    if (rc) {
        kfree(tw);
        pr_err("KSUBIRTH task_work_add pid=%d rc=%d(most likely exiting)\n", current->pid, rc);
        return;
    }
    atomic_inc(&ksu_birth_queued);
    pr_info("KSUBIRTH queued self fd pid=%d comm=[%s] queued=%d\n",
            current->pid, current->comm, atomic_read(&ksu_birth_queued));
}

/* Called from the sys_enter tracepoint (hook/syscall_hook_manager.c). Cheap on the way out:
 * three compares for every task that is not the Manager's main thread. */
void ksu_mgr_birth_check(void)
{
    struct task_struct *t = current;
    unsigned long long st;

    if (t != t->group_leader)
        return;
    if (!ksu_is_manager_appid_valid() || !is_uid_manager(current_uid().val))
        return;
    st = (unsigned long long)t->start_time;
    if (READ_ONCE(ksu_birth_pid) == t->pid && READ_ONCE(ksu_birth_start) == st)
        return;                        /* this exact process was already queued */
    WRITE_ONCE(ksu_birth_pid, t->pid);
    WRITE_ONCE(ksu_birth_start, st);
    pr_info("KSUBIRTH seen Manager pid=%d uid=%u start=%llu - queue before its own one-shot query\n",
            t->pid, current_uid().val, st);
    ksu_fd_install_self_tw();
}
"""

CALL = r"""
    /* rc74(md 6.413)：Manager 出生即装 fd。见 infra/dev_syms.c 的 ksu_mgr_birth_check()。
     * 放在 dispatcher 检查之后、所有打印之前：它必须比这块屏自己的那次一次性查询早，
     * 而这条 tracepoint 是全机每条 syscall 都过的地方，没有比它更早还更便宜的位置了。
     * 谓词里不许睡眠(此处在 preempt-disabled 的 probe 里)，分配只有 GFP_ATOMIC。 */
    if (unlikely(ksu_mgr_birth_fd))
        ksu_mgr_birth_check();
"""

DECL = r"""/* rc74(md 6.413)：出生即装的那块状态在 infra/dev_syms.c 里(那把文件才是驱动 fd 的家)。
 * 这里只声明两个符号，不动任何头文件。 */
extern int ksu_mgr_birth_fd;
extern void ksu_mgr_birth_check(void);

"""


def patch_devsyms():
    s = rd(DS)
    if "KSUBIRTH" in s:
        print("  [skip] dev_syms.c 已经有 KSUBIRTH(已打过)  md5=%s" % md5(DS)[:8])
        return
    cur = md5(DS)
    if cur != WANT_DS:
        print("[x] dev_syms.c 不是 rc73 那份(实得 %s，期望 %s)⇒ 不打，先让构建脚本还原" % (cur[:8], WANT_DS[:8]))
        sys.exit(1)
    if "void ksu_fd_install_run(void)" not in s:
        print("[x] dev_syms.c 里找不到 ksu_fd_install_run ⇒ 这份底说不出来源，停")
        sys.exit(1)
    if s.count("static void ksu_fd_install_tw_func") < 1:
        print("[x] dev_syms.c 里没有 ksu_fd_install_tw_func(回调本体) ⇒ 停")
        sys.exit(1)
    if "manager_identity" not in s and "is_uid_manager" not in s:
        # 谓词来自 manager/manager_identity.h；current_uid() 来自 linux/cred.h。
        # 锚点要**唯一**才算数(例 153：在坏文件上硬插=静默换形状)。
        anchor = "#include <linux/task_work.h>"
        if s.count(anchor) != 1:
            anchor = "#include <linux/pid.h>"
        if s.count(anchor) != 1:
            print("[x] dev_syms.c 里找不到唯一的 include 锚点(task_work.h / pid.h)⇒ 停")
            sys.exit(1)
        s = s.replace(anchor, anchor + "\n#include \"manager/manager_identity.h\" /* rc74: is_uid_manager()/ksu_is_manager_appid_valid() */\n#include <linux/cred.h>          /* rc74: current_uid() */\n", 1)
        print("  已补 include(锚=%s)：manager_identity.h + cred.h" % anchor)
    s = s + BLOCK
    wr(DS, s)
    print("  dev_syms.c 追加 %d 字节；KSUBIRTH 串=%d 新 md5=%s" % (len(BLOCK), s.count("KSUBIRTH"), md5(DS)[:8]))


def patch_manager():
    s = rd(SH)
    if "ksu_mgr_birth_check" in s:
        print("  [skip] syscall_hook_manager.c 已打过  md5=%s" % md5(SH)[:8])
        return
    cur = md5(SH)
    if cur != WANT_SH:
        print("[x] syscall_hook_manager.c 不是 rc73 树里那份(实得 %s 期望 %s)⇒ 停" % (cur[:8], WANT_SH[:8]))
        sys.exit(1)
    a1 = "static void ksu_sys_enter_handler(void *data, struct pt_regs *regs, long id)"
    if s.count(a1) != 1:
        print("[x] handler 定义那行命中 %d(应 1)⇒ 停" % s.count(a1))
        sys.exit(1)
    s = s.replace(a1, DECL + a1, 1)
    a2 = "    if (ksu_dispatcher_nr < 0)\n        return;\n"
    if s.count(a2) != 1:
        print("[x] dispatcher 早退那段命中 %d(应 1)⇒ 停(形状变了就别硬打)" % s.count(a2))
        sys.exit(1)
    s = s.replace(a2, a2 + CALL, 1)
    wr(SH, s)
    print("  syscall_hook_manager.c 打完；调用点=%d 新 md5=%s" % (s.count("ksu_mgr_birth_check();"), md5(SH)[:8]))


print("=== w685 出生即装补丁 target=%s ===" % M)
print("  打前：dev_syms=%s  manager=%s" % (md5(DS)[:8], md5(SH)[:8]))
patch_devsyms()
patch_manager()
print("  打后：dev_syms=%s  manager=%s" % (md5(DS)[:8], md5(SH)[:8]))
d = rd(DS)
m = rd(SH)
# 期望值**从要追加的那段自己数**，不是我手写的魔数(第一版拍了 >=5，实际那段里 KSUBIRTH 出现 4 次 ⇒ 补丁
# 已经打对了却被自己的断言判死——例 163 那一族：闸把我拍的数当不变量)。
WANT_KS = BLOCK.count("KSUBIRTH")
assert d.count("KSUBIRTH") >= WANT_KS, "KSUBIRTH 串=%d，比追加段里的 %d 还少 ⇒ 追加没真落地" % (d.count("KSUBIRTH"), WANT_KS)
assert "ksu_mgr_birth_check();" in m
assert "GFP_KERNEL" in d
print("  自检：dev_syms 里 KSUBIRTH=%d(>=追加段的 %d)；新增段里 GFP_ATOMIC=%d 次；调用点=%d"
      % (d.count("KSUBIRTH"), WANT_KS, d.count("GFP_ATOMIC"), m.count("ksu_mgr_birth_check();")))
print("=== w685 完成 ===")
