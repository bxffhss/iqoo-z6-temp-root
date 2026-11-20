#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w689_add_birthfd2.py —— rc74b：把「Manager 出生即装 fd」那一段的**去重**与**谓词宽度**修对。
   跑法(在构建机上)：python3 /home/lucy/w689_add_birthfd2.py /root/k/ksu/kernel
   起因＝第 50 发一手(md §6.414)：机制判正(不跑腿牌子自己亮)，但同发抓到
     ①**去重形同虚设**：rc74 用的是**单槽**缓存 `ksu_birth_pid/ksu_birth_start`，而 Manager 一家子
        (主进程 + 它 fork 的 `sh`/`id`/`libksud.so`，uid 都是 10104)在同 10 秒里交替开火 ⇒ 彼此把槽顶掉
        ⇒ 一手读数：同一个 `pid=13318 comm=[sh] start=1724956878195` 三次入队；`seen/queued/=> fd=` 各 149；
        Manager 表里 `ksu_driver` 从 14 条涨到 **75** 条 = **驱动 fd 泄漏**。
     ②**谓词比设计的宽**：`group_leader ∧ is_uid_manager(10104)` 放进了 Manager 自己 spawn 的子进程
        (它们是独立进程组的领头)。牌子只认主进程(§6.406/§6.414)，子进程那份 fd 在 rc73 的形状里根本没有
        ⇒ 相对 rc73 的唯一变化应当只有「主进程装一次」。
   这一版怎么改(两块都还是"只加不改"，rc73 的护栏与那五条 args 一个字不动)：
     A) **环状去重**：`ksu_birth_ring[16]` 存 `(pid, start_time)`，命中就跳过；满了按 `start_time` 最小者
        (最老出生的)腾位 ⇒ 一个活进程**至多排一次**，最坏情况被顶出后由 `cap` 兜底(见 C)。
        `start_time` 保留是有原因的：pid 会被回收再用，只看 pid 会把新进程误判成「已经装过」——这条单独有测试格。
     B) **只认主进程**：`t->real_parent` 的 uid 与我相同 ⇒ 这是 Manager 自己 fork 出来的 ⇒ 不排
        (取 cred 走 `rcu_read_lock()/__task_cred()`，probe 里合法、不睡)。
     C) **硬上限** `ksu_mgr_birth_cap`(默认 64)：本 boot 排过头就不排了，并打 `KSUBIRTH cap`(printk 限流)。
        去重命中/子进程命中这两条**不打印**(它们在热路径上会刷爆 console——§6.118 那次整机复位就是这个形状)，
        只各留一条**每 256 次一次**的计数证人(`KSUBIRTH dupskip n=`/`KSUBIRTH childskip n=`)，
        这样"闸真在挡"有一手读数，而"挡住"本身不会把机器拖死。
   ★红线(同 rc74，一条都没松)：
     · tracepoint 回调在 **preempt-disabled** 下跑 ⇒ 分配只许 `GFP_ATOMIC`，不许任何可能睡眠的东西；
       环的读写在**自旋锁**里(带 irq save)，装 fd 的 `task_work_add` 在锁外。
     · 不引入新导出符号、不动 `__versions` ⇒ 装入门径逐字同 rc73/rc74。
     · `!current->files` 那把 rc73 护栏留着(排的还是同一个回调)。
   ★可测性(例 172：夹具不共用被测代码就只证明夹具自洽)：判定函数 `ksu_birth_gate()` 是**纯函数**
     (只有 int/struct 参数，不碰任何内核 API)，并用 BEGIN/END 标记圈起来 ⇒ `kmod/w691_birth_test.py`
     在构建机上**从打完补丁的那份文件里抠出这段原文**、用 gcc 编到宿主上跑真值表 ⇒ 测的就是上机的那段字节。
   幂等：文件里已经有 `KSUBIRTH-PURE` 就跳过(并核 md5)。
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

PURE_BEGIN = "/* BEGIN KSUBIRTH-PURE */"
PURE_END = "/* END KSUBIRTH-PURE */"


def md5(p):
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()


def rd(p):
    return io.open(p, encoding="utf-8", errors="surrogateescape").read()


def wr(p, s):
    io.open(p, "w", encoding="utf-8", newline="", errors="surrogateescape").write(s)


# ---- 纯判定函数(被宿主测试原样抠走)：返回值就是它为什么放行/为什么挡住 ----
PURE = r"""/* BEGIN KSUBIRTH-PURE */
/* rc74b gate: pure over plain ints so the SAME bytes can be host-compiled and truth-tabled.
 * return: 1 = queue now; 2 not a leader; 3 not the crowned manager uid; 4 child of the manager
 * itself; 5 already queued for this exact (pid, start_time); 6 boot cap hit.
 * It claims the slot only when it returns 1. */
struct ksu_birth_ent {
	int pid;
	unsigned long long start;
};

static int ksu_birth_gate(struct ksu_birth_ent *ring, int ring_max, int *ring_nr,
                          int *total, int cap,
                          int is_leader, int uid_ok, int parent_is_mgr,
                          int pid, unsigned long long start)
{
	int i, s;

	if (!is_leader)
		return 2;
	if (!uid_ok)
		return 3;
	if (parent_is_mgr)
		return 4;
	for (i = 0; i < *ring_nr; i++)
		if (ring[i].pid == pid && ring[i].start == start)
			return 5;
	if (*total >= cap)
		return 6;
	(*total)++;
	if (*ring_nr < ring_max) {
		ring[*ring_nr].pid = pid;
		ring[*ring_nr].start = start;
		(*ring_nr)++;
	} else {
		/* ring full: recycle the OLDEST-born entry (smallest start_time). An evicted live
		 * process can queue again, but only until cap - that is the bounded blast radius. */
		s = 0;
		for (i = 1; i < ring_max; i++)
			if (ring[i].start < ring[s].start)
				s = i;
		ring[s].pid = pid;
		ring[s].start = start;
	}
	return 1;
}

/* Undo a claim when the atomic allocation behind it failed, so the process is not silently
 * blacklisted for the whole boot. */
static void ksu_birth_forget(struct ksu_birth_ent *ring, int *ring_nr, int pid,
                             unsigned long long start)
{
	int i, j;

	for (i = 0; i < *ring_nr; i++) {
		if (ring[i].pid == pid && ring[i].start == start) {
			for (j = i; j < *ring_nr - 1; j++)
				ring[j] = ring[j + 1];
			(*ring_nr)--;
			return;
		}
	}
}
/* END KSUBIRTH-PURE */"""

BLOCK = r"""

/* ===== rc74b(md 6.414/6.415)：Manager 出生即装驱动 fd 的修正版；调用点在 hook/syscall_hook_manager.c =====
 * 第 50 发把机制判正了(不跑腿牌子自己亮)，同时抓到两处：单槽去重被 Manager 一家的多个 pid 交替顶穿
 * (=> 驱动 fd 泄漏，主进程表里 14->68->75 条)，以及谓词把它的 sh/id/libksud.so 子进程也放进来。
 * 这一版：环状去重 + 只认主进程 + 每 boot 硬上限。热路径上**不打印**挡住的分支，只留限流计数证人。
 * 红线不变：preempt-disabled 的 probe 里只许 GFP_ATOMIC；不动 __versions/导出符号；rc73 的 files==NULL 护栏留着。
 * ksu_mgr_birth_fd 默认 1(开) => 出货 ksu_args.txt 一个字不改(那五条是装载期致死轴)。退回 rc73 形状：
 * insmod 多带 ksu_mgr_birth_fd=0(只在实验/对照里用)。 */
int ksu_mgr_birth_fd = 1;
module_param(ksu_mgr_birth_fd, int, 0444);
MODULE_PARM_DESC(ksu_mgr_birth_fd, "1=install driver fd once into the official Manager main process at its first syscall (0 = exactly rc73)");

int ksu_mgr_birth_cap = 64;         /* per-boot ceiling of birth-installs; the fd leak of rc74 is the reason it exists */
module_param(ksu_mgr_birth_cap, int, 0444);
MODULE_PARM_DESC(ksu_mgr_birth_cap, "max birth-installs per boot (rc74 leaked driver fds without such a ceiling)");

#define KSU_BIRTH_RING 16

/* struct ksu_birth_ent 与判定函数 ksu_birth_gate()/ksu_birth_forget() 都在下面那段被标记的**纯**区域里
 * (宿主测试 w691 原样抠走编译，所以它们必须在标记内)。 */

__PURE__

static struct ksu_birth_ent ksu_birth_ring[KSU_BIRTH_RING];
static int ksu_birth_ring_nr;
static int ksu_birth_total;
static atomic_t ksu_birth_dupskip = ATOMIC_INIT(0);
static atomic_t ksu_birth_childskip = ATOMIC_INIT(0);
static DEFINE_SPINLOCK(ksu_birth_lock);

static void ksu_fd_install_self_tw(int pid, unsigned long long start)
{
	struct ksu_fd_install_tw *tw;
	unsigned long flags;
	int rc;

	/* preempt-disabled context: GFP_ATOMIC only. Under memory pressure this just means
	 * "no birth-install this round" - the /proc/ksu_install_fd port still works. */
	tw = kzalloc(sizeof(*tw), GFP_ATOMIC);
	if (!tw) {
		pr_err("KSUBIRTH kzalloc(ATOMIC) failed pid=%d - no birth fd this round\n", pid);
		spin_lock_irqsave(&ksu_birth_lock, flags);
		ksu_birth_forget(ksu_birth_ring, &ksu_birth_ring_nr, pid, start);
		spin_unlock_irqrestore(&ksu_birth_lock, flags);
		return;
	}
	init_task_work(&tw->cb, ksu_fd_install_tw_func);
	tw->pid = pid;
	/* this tree's task_work_add() takes a bool (include/linux/task_work.h) */
	rc = task_work_add(current, &tw->cb, true);
	if (rc) {
		kfree(tw);
		pr_err("KSUBIRTH task_work_add pid=%d rc=%d(most likely exiting)\n", pid, rc);
		spin_lock_irqsave(&ksu_birth_lock, flags);
		ksu_birth_forget(ksu_birth_ring, &ksu_birth_ring_nr, pid, start);
		spin_unlock_irqrestore(&ksu_birth_lock, flags);
		return;
	}
	pr_info("KSUBIRTH queued self fd pid=%d comm=[%s] total=%d slots=%d\n",
		pid, current->comm, ksu_birth_total, ksu_birth_ring_nr);
}

/* Called from the sys_enter tracepoint (hook/syscall_hook_manager.c). For every task that is
 * not the Manager's main thread this is: one pointer compare, one uid compare, one rcu-protected
 * parent uid read. Blocked paths never print (that is what flooded the console in rc74). */
void ksu_mgr_birth_check(void)
{
	struct task_struct *t = current;
	unsigned long long st = (unsigned long long)t->start_time;
	int pu, r;
	unsigned long flags;

	if (t != t->group_leader)
		return;
	if (!ksu_is_manager_appid_valid() || !is_uid_manager(current_uid().val))
		return;
	rcu_read_lock();
	pu = (__task_cred(t->real_parent)->uid.val == current_uid().val);
	rcu_read_unlock();

	spin_lock_irqsave(&ksu_birth_lock, flags);
	r = ksu_birth_gate(ksu_birth_ring, KSU_BIRTH_RING, &ksu_birth_ring_nr,
			   &ksu_birth_total, ksu_mgr_birth_cap, 1, 1, pu,
			   t->pid, st);
	spin_unlock_irqrestore(&ksu_birth_lock, flags);

	if (r != 1) {
		if (r == 4) {
			int n = atomic_inc_return(&ksu_birth_childskip);
			if ((n & 255) == 1)
				pr_info("KSUBIRTH childskip n=%d pid=%d comm=[%s] - spawned by the manager itself, only the main process gets a birth fd\n",
					n, t->pid, t->comm);
		} else if (r == 5) {
			int n = atomic_inc_return(&ksu_birth_dupskip);
			if ((n & 255) == 1)
				pr_info("KSUBIRTH dupskip n=%d pid=%d - already queued for this exact process\n",
					n, t->pid);
		} else if (r == 6) {
			pr_err("KSUBIRTH cap total=%d cap=%d - refusing more birth fds this boot\n",
				ksu_birth_total, ksu_mgr_birth_cap);
		}
		return;
	}
	pr_info("KSUBIRTH seen Manager pid=%d uid=%u start=%llu total=%d slots=%d - queue before its own one-shot query\n",
		t->pid, current_uid().val, st, ksu_birth_total, ksu_birth_ring_nr);
	ksu_fd_install_self_tw(t->pid, st);
}
"""

CALL = r"""
    /* rc74b(md 6.414)：Manager 出生即装 fd(现在一个进程只排一次，且只认主进程)。
     * 见 infra/dev_syms.c 的 ksu_mgr_birth_check()。放在 dispatcher 早退之后：
     * 它必须比这块屏自己那次一次性查询早，而这条 tracepoint 是全机每条 syscall 都过的地方。
     * 谓词里不许睡眠(此处在 preempt-disabled 的 probe 里)，分配只有 GFP_ATOMIC。 */
    if (unlikely(ksu_mgr_birth_fd))
        ksu_mgr_birth_check();
"""

DECL = r"""/* rc74b(md 6.414)：出生即装的状态在 infra/dev_syms.c 里(那把文件才是驱动 fd 的家)。
 * 这里只声明两个符号，不动任何头文件。 */
extern int ksu_mgr_birth_fd;
extern void ksu_mgr_birth_check(void);

"""


def patch_devsyms():
    s = rd(DS)
    if "KSUBIRTH-PURE" in s:
        print("  [skip] dev_syms.c 已经是 rc74b 那份(已打过)  md5=%s" % md5(DS)[:8])
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
    if "if (unlikely(!current->files))" not in s:
        print("[x] dev_syms.c 里没有 rc73 那把 files==NULL 护栏(期望 e0da5e8c 那份) ⇒ 停：底不对")
        sys.exit(1)
    if "manager_identity" not in s and "is_uid_manager" not in s:
        anchor = "#include <linux/task_work.h>"
        if s.count(anchor) != 1:
            anchor = "#include <linux/pid.h>"
        if s.count(anchor) != 1:
            print("[x] dev_syms.c 里找不到唯一的 include 锚点(task_work.h / pid.h)⇒ 停")
            sys.exit(1)
        s = s.replace(anchor, anchor + "\n#include \"manager/manager_identity.h\" /* rc74b: is_uid_manager()/ksu_is_manager_appid_valid() */\n#include <linux/cred.h>          /* rc74b: current_uid()/__task_cred() */\n", 1)
        print("  已补 include(锚=%s)：manager_identity.h + cred.h" % anchor)
    body = BLOCK.replace("__PURE__", PURE)
    if s.count(PURE_BEGIN) != 0 or s.count(PURE_END) != 0:
        print("[x] 底里已经有一对 KSUBIRTH-PURE 标记 ⇒ 形状不明，停")
        sys.exit(1)
    wr(DS, s + body)
    d = rd(DS)
    print("  dev_syms.c 追加 %d 字节；PURE 标记对=%d(必须各 1) KSUBIRTH 串=%d 新 md5=%s"
          % (len(body), d.count(PURE_BEGIN), d.count("KSUBIRTH"), md5(DS)[:8]))


def patch_manager():
    s = rd(SH)
    if "ksu_mgr_birth_check" in s:
        print("  [skip] syscall_hook_manager.c 已打过调用点  md5=%s" % md5(SH)[:8])
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


print("=== w689 rc74b 补丁 target=%s ===" % M)
print("  打前：dev_syms=%s  manager=%s" % (md5(DS)[:8], md5(SH)[:8]))
patch_devsyms()
patch_manager()
d, m = rd(DS), rd(SH)
print("  打后：dev_syms=%s  manager=%s" % (md5(DS)[:8], md5(SH)[:8]))

# ---- 现数断言(期望值从要写进去的那段自己数，不是我手拍的魔数：例 173④) ----
assert d.count(PURE_BEGIN) == 1 and d.count(PURE_END) == 1, "PURE 标记不成对⇒宿主测试抠不出原文"
assert d.count("ksu_birth_gate(") >= PURE.count("ksu_birth_gate("), "gate 调用没落进文件"
assert d.count("ksu_birth_forget(") >= 2, "分配失败回滚那两格没落地(否则进程会被永久拉黑)"
# 底里本来就有一处 GFP_KERNEL(在 /proc 那条**进程上下文**的支路 line1978，合法)；
# 新增段里一处都不许有——那条闸在构建脚本里按"从 PURE 标记到文件尾"这段现数，别在这儿数全文件。
assert d.count("GFP_KERNEL") == 1, "底里那处合法的 GFP_KERNEL 竟然变了数 ⇒ 这份底说不出来源"
assert "GFP_ATOMIC" in d and d.count("GFP_ATOMIC") == BLOCK.count("GFP_ATOMIC"), "GFP_ATOMIC 条数与源码段不符"
assert m.count("ksu_mgr_birth_check();") == 1, "调用点条数不对"
assert "rc74b" in m, "调用点注释没落地"
print("  自检：PURE 标记对=1；gate 调用=%d；forget=%d；GFP_ATOMIC=%d(=段内 %d)；GFP_KERNEL 全文件=%d(底里那处合法的那 1)；调用点=1；KSUBIRTH 串=%d"
      % (d.count("ksu_birth_gate("), d.count("ksu_birth_forget("), d.count("GFP_ATOMIC"),
         BLOCK.count("GFP_ATOMIC"), d.count("GFP_KERNEL"), d.count("KSUBIRTH")))
print("=== w689 完成 ===")
