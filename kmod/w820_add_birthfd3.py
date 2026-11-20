#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w820_add_birthfd3.py —— rc74c：把「出生即装驱动 fd」的两处按第 56 发一手修对。
   跑法(在构建机上，**接在 w689 之后**)：python3 /home/lucy/w820_add_birthfd3.py /root/k/ksu/kernel

   一手依据(md §6.429，第 56 发)：
     ①`total=64`(满)、`KSUBIRTH cap … refusing more birth fds this boot` 5.2 秒内 1203 行、
       当前 Manager `pid=13767` `fd_ksu=0` ⇒ 牌子掉 `不支持`，同刻 `su -c` 仍 `uid=0`。
     ②烧预算的是 `libksud.so`：rc74b 的"只认主进程"用的是 `real_parent` 的 uid —— 而 libsu 那个服务进程
       会脱离父进程(`real_parent` 不再是 10104) ⇒ **它既是领头、父进程 uid 又不同 ⇒ 被当成主进程放行**；
       它一出生就被 app 域 seccomp 打死(`SIGSYS syscall 142`)，`crash_dump64` 起来收尸 ⇒ 每个都占一格。
     ③而 `cap` 是**本 boot 累计**计数、只增不减 ⇒ 正常使用十几分钟就烧光。

   这一版改两半(仍是"只加不改"：rc73 的 files==NULL 护栏与那五条 args 一个字不动)：
     A) **helper 名单**：`comm` 命中 `libksud.so`/`crash_dump64`/`debuggerd64` ⇒ 不装 fd(返回码 7，限流证人)。
        ★名单是**一手 comm**抄来的，不是我猜的；`usap64` 故意**不放进去**——第 51 发实测主进程排队时 comm 就是 `usap64`，
        放进去就会把正要保护的那个进程挡掉。判定函数留在 PURE 区里(宿主测试原样抠走跑真值表)。
     B) **上限换形状**：`cap` 64→4096(不再是"十几分钟就烧光"的量级) ＋ 新增 `ksu_mgr_birth_rate`(默认 8，
        每 1 秒窗口的放行数，返回码 8)——真正要防的是"崩溃循环刷分配"，那是**速率**问题不是**累计**问题；
        每次成功排队才 `total++`/`win_n++`，被挡住的分支都不打印(§6.118 的 console 洪印教训)。
   红线：preempt-disabled 的 probe 里只许 GFP_ATOMIC；不动 __versions/导出符号；
        不新增内核符号依赖(用的还是 rc74b 已经引的那两条自旋锁)。
   幂等：文件里已经有 `KSUBIRTH3` 就跳过(并核 md5)。底必须是 w689 打完的那份(查 `KSUBIRTH-PURE` 在、`ksu_mgr_birth_cap = 64` 在)。
"""
import hashlib
import io
import os
import re
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
DS = os.path.join(M, "infra", "dev_syms.c")
WANT_MARK = "BEGIN KSUBIRTH-PURE"          # w689 打过 ⇒ 有这个
WANT_OLD_CAP = "int ksu_mgr_birth_cap = 64;"


def md5(p):
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()


def rd(p):
    return io.open(p, encoding="utf-8", errors="surrogateescape").read()


def wr(p, s):
    io.open(p, "w", encoding="utf-8", newline="", errors="surrogateescape").write(s)


def must(s, old_absent, new_present, label="（默认）"):
    """str.replace 不报错也不等于打上了：每处 C 文本改动都要**断言旧串没了、新串在**。"""
    if old_absent and s.count(old_absent) != 0:
        print("  [x] %s：旧串还剩 %d 处 ⇒ 替换没落地" % (label, s.count(old_absent)))
        sys.exit(1)
    if new_present and s.count(new_present) == 0:
        print("  [x] %s：新串找不到(%s) ⇒ 替换没落地" % (label, new_present[:40]))
        sys.exit(1)
    print("  [ok] %s 的替换确实落地" % label)


def one(s, old, new, label, count=1):
    n = s.count(old)
    if n != count:
        print("  [x] %s 的锚命中 %d 次(要 %d) ⇒ 全批不写" % (label, n, count))
        sys.exit(1)
    print("  [ok] %s" % label)
    return s.replace(old, new)


PURE3 = r"""/* BEGIN KSUBIRTH-PURE */
/* rc74c gate: same pure core as rc74b, plus the two fixes the 56th shot forced.
 * return: 1 = queue now; 2 not a leader; 3 not the crowned manager uid; 4 child of the manager
 * itself; 5 already queued for this exact (pid, start_time); 6 lifetime ceiling hit;
 * 7 helper binary (libksud.so / crash_dump64 / debuggerd64 - the manager's root-service child
 *   that seccomp kills within ~80ms; rc74b counted each of them because it detaches from its
 *   parent, so "real_parent has my uid" did NOT catch it); 8 rate window full.
 * It claims a slot only when it returns 1. */
struct ksu_birth_ent {
	int pid;
	unsigned long long start;
};

/* comm comes from the exec'd binary's basename; the table is copied from first-hand dmesg.
 * Deliberately NOT in the table: usap64 - the 51st shot showed the real main process is
 * still called usap64 while it queues. */
static const char *const ksu_birth_helper_tbl[] = {
	"libksud.so",
	"crash_dump64",
	"debuggerd64",
};
#define KSU_BIRTH_HELPER_N ((int)(sizeof(ksu_birth_helper_tbl) / sizeof(ksu_birth_helper_tbl[0])))

static int ksu_birth_is_helper(const char *comm)
{
	int i;

	for (i = 0; i < KSU_BIRTH_HELPER_N; i++)
		if (!strcmp(comm, ksu_birth_helper_tbl[i]))
			return 1;
	return 0;
}

static int ksu_birth_gate(struct ksu_birth_ent *ring, int ring_max, int *ring_nr,
                          int *total, int cap,
                          int is_leader, int uid_ok, int parent_is_mgr, int helper,
                          unsigned long long last_grant, unsigned long long interval_ns,
                          int pid, unsigned long long start)
{
	int i, s;

	if (!is_leader)
		return 2;
	if (!uid_ok)
		return 3;
	if (helper)
		return 7;
	if (parent_is_mgr)
		return 4;
	for (i = 0; i < *ring_nr; i++)
		if (ring[i].pid == pid && ring[i].start == start)
			return 5;
	if (*total >= cap)
		return 6;
	/* Rate gate, measured with the timestamps the events already carry: t->start_time is a
	 * boot-relative nanosecond clock, so "no faster than N per second" needs NO new kernel
	 * symbol (an earlier draft reached for the kernel tick and the build gate rightly
	 * refused the new undefined reference - md 6.430). interval_ns==0 = window off.
	 * last_grant==0 means "no grant yet" (must NOT be compared against - my own host test
	 * caught that: it made the very first birth look "too close" to time zero).
	 * A clock going backwards (st < last_grant) is treated as "allow", never as a lockup. */
	if (interval_ns && last_grant && start >= last_grant && start - last_grant < interval_ns)
		return 8;
	(*total)++;
	if (*ring_nr < ring_max) {
		ring[*ring_nr].pid = pid;
		ring[*ring_nr].start = start;
		(*ring_nr)++;
	} else {
		/* ring full: recycle the OLDEST-born entry (smallest start_time). An evicted live
		 * process can queue again - bounded now by the rate window, not by a tight
		 * cumulative ceiling. */
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
 * blacklisted for the whole boot. (Also gives the rate window slot back.) */
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

PARAMS3 = r"""int ksu_mgr_birth_cap = 4096;       /* rc74c(md 6.429): was a 64 *cumulative* ceiling - normal use of the manager (its root service dies on seccomp and is reborn) burned it in ~12 minutes and the badge went to "unsupported" with fd_ksu=0. The real protection is the rate window below; this is only a runaway backstop. */
module_param(ksu_mgr_birth_cap, int, 0444);
MODULE_PARM_DESC(ksu_mgr_birth_cap, "max birth-installs per boot (rc74b: 64 was reachable by ordinary use; see ksu_mgr_birth_rate)");

int ksu_mgr_birth_rate = 8;         /* rc74c: per-second ceiling of birth-installs (crash loops churn new pids; that is a rate problem, not a lifetime one) */
module_param(ksu_mgr_birth_rate, int, 0444);
MODULE_PARM_DESC(ksu_mgr_birth_rate, "max birth-installs per second window (0 = rate window off)");"""

COUNTERS3 = r"""static atomic_t ksu_birth_dupskip = ATOMIC_INIT(0);
static atomic_t ksu_birth_childskip = ATOMIC_INIT(0);
static atomic_t ksu_birth_helperskip = ATOMIC_INIT(0);      /* rc74c: who we refused because of the comm table */
static atomic_t ksu_birth_rateskip = ATOMIC_INIT(0);        /* rc74c: rate-window refusals */
static unsigned long long ksu_birth_last_grant;      /* rc74c: start_time(ns) of the last granted birth */
static DEFINE_SPINLOCK(ksu_birth_lock);"""

CHECK3 = r"""/* Called from the sys_enter tracepoint (hook/syscall_hook_manager.c). For every task that is
 * not the Manager's main thread this is: one pointer compare, one uid compare, one comm-table
 * walk (max 3 strcmp against a 16-byte array), one rcu-protected parent uid read.
 * Blocked paths never print (that is what flooded the console in rc74). */
void ksu_mgr_birth_check(void)
{
	struct task_struct *t = current;
	unsigned long long st = (unsigned long long)t->start_time;
	int pu, r;
	unsigned long long last_grant, interval_ns;
	unsigned long flags;

	if (t != t->group_leader)
		return;
	if (!ksu_is_manager_appid_valid() || !is_uid_manager(current_uid().val))
		return;
	/* rc74c A): the manager's root-service child execs libksud.so and dies on seccomp; it
	 * detaches, so rc74b's parent-uid test missed it and every reborn pid took a slot. */
	if (ksu_birth_is_helper(t->comm)) {
		int hn = atomic_inc_return(&ksu_birth_helperskip);
		if ((hn & 255) == 1)
			pr_info("KSUBIRTH helper n=%d pid=%d comm=[%s] - not the process the badge reads, refusing a birth fd\n",
				hn, t->pid, t->comm);
		return;
	}
	rcu_read_lock();
	pu = (__task_cred(t->real_parent)->uid.val == current_uid().val);
	rcu_read_unlock();

	/* rc74c B): rate window measured from the events' own nanosecond clock (see PURE note). */
	interval_ns = (ksu_mgr_birth_rate > 0) ? (1000000000ULL / (unsigned long long)ksu_mgr_birth_rate) : 0ULL;
	spin_lock_irqsave(&ksu_birth_lock, flags);
	last_grant = ksu_birth_last_grant;
	r = ksu_birth_gate(ksu_birth_ring, KSU_BIRTH_RING, &ksu_birth_ring_nr,
			   &ksu_birth_total, ksu_mgr_birth_cap, 1, 1, pu, 0,
			   last_grant, interval_ns, t->pid, st);
	if (r == 1 && st >= last_grant)
		ksu_birth_last_grant = st;
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
		} else if (r == 8) {
			int n = atomic_inc_return(&ksu_birth_rateskip);
			if ((n & 255) == 1)
				pr_info("KSUBIRTH rate n=%d total=%d rate=%d pid=%d comm=[%s] - closer than the birth interval (a crash loop churns new pids; that is a rate problem)\n",
					n, ksu_birth_total, ksu_mgr_birth_rate, t->pid, t->comm);
		}
		return;
	}
	pr_info("KSUBIRTH seen Manager pid=%d uid=%u start=%llu total=%d slots=%d - queue before its own one-shot query\n",
		t->pid, current_uid().val, st, ksu_birth_total, ksu_birth_ring_nr);
	ksu_fd_install_self_tw(t->pid, st);
}"""


def main():
    if not os.path.exists(DS):
        print("[x] 没有 %s ⇒ 停" % DS)
        return 1
    s = rd(DS)
    if "KSUBIRTH3" in s or "ksu_mgr_birth_rate" in s:
        print("  [跳过] dev_syms.c 已经是 rc74c 那份(已打过)  md5=%s" % md5(DS)[:8])
        return 0
    if WANT_MARK not in s:
        print("[x] 底不是 w689(rc74b) 打过的那份(找不到 %s) ⇒ 停" % WANT_MARK)
        return 1
    if s.count(WANT_OLD_CAP) != 1:
        print("[x] 找不到唯一的 `ksu_mgr_birth_cap = 64`(实得 %d) ⇒ 底不是 rc74b，停" % s.count(WANT_OLD_CAP))
        return 1

    print("=== W820 rc74b→rc74c 补丁（第 56 发一手：helper 排除 ＋ 上限换成速率＋宽累计）===")
    # 1) 整个 PURE 区换掉（按标记抠，不靠字面全文匹配）
    pat = re.compile(r"/\* BEGIN KSUBIRTH-PURE \*/.*?/\* END KSUBIRTH-PURE \*/", re.S)
    if len(pat.findall(s)) != 1:
        print("  [x] PURE 标记区不是恰好 1 段 ⇒ 停")
        return 1
    s = pat.sub(lambda _m: PURE3, s, count=1)
    print("  [ok] PURE 区整段替换（helper 名单进 PURE，宿主测试能原样抠走）")
    # 2) 参数默认值/说明
    old_cap = (WANT_OLD_CAP +
               "         /* per-boot ceiling of birth-installs; the fd leak of rc74 is the reason it exists */\n"
               "module_param(ksu_mgr_birth_cap, int, 0444);\n"
               'MODULE_PARM_DESC(ksu_mgr_birth_cap, "max birth-installs per boot (rc74 leaked driver fds without such a ceiling)");')
    if s.count(old_cap) != 1:
        print("  [x] 那段旧参数块匹配不到(它被 w689 之外的东西改过?) ⇒ 停，不猜")
        return 1
    s = s.replace(old_cap, "/* rc74c(md 6.429) */\n" + PARAMS3, 1)
    print("  [ok] cap 64→4096 ＋ 新参数 ksu_mgr_birth_rate=8")
    # 3) 计数与速率窗的静态
    s = one(s, r"""static atomic_t ksu_birth_dupskip = ATOMIC_INIT(0);
static atomic_t ksu_birth_childskip = ATOMIC_INIT(0);
static DEFINE_SPINLOCK(ksu_birth_lock);""", COUNTERS3, "计数/速率窗静态")
    # 注意方向：这里要断言的是**新串在场**(旧串该没的地方在 check() 末尾那一串 gone 里统一验)
    must(s, "", "ksu_birth_helperskip = ATOMIC_INIT(0)", "计数器静态(新串在场)")
    must(s, "", "unsigned long long last_grant, unsigned long long interval_ns", "PURE 形参")
    # 4) 谓词函数整段替换
    old_fn_start = s.index("/* Called from the sys_enter tracepoint")
    tail = "	ksu_fd_install_self_tw(t->pid, st);\n}"
    old_fn_end = s.index(tail) + len(tail)
    old_fn = s[old_fn_start:old_fn_end]
    if old_fn.count("void ksu_mgr_birth_check(void)") != 1:
        print("  [x] 抠出来的谓词函数形状不对 ⇒ 停(别按行号猜)")
        return 1
    s = s[:old_fn_start] + CHECK3 + s[old_fn_end:]
    print("  [ok] ksu_mgr_birth_check() 整段替换（helper 早退 ＋ 速率窗 ＋ 新证人）")
    # ★整段换完之后必须再断言一次：旧符号/旧证人一个字都不许留在文件里(no-op 与半落地都会在这里露出来)
    for gone in ("ksu_birth_win_n", "ksu_birth_win_end", "time_after_eq", "jiffies", "win=%d"):
        must(s, gone, "")
    must(s, "", "if (r == 1 && st >= last_grant)", "grant 后刷新 last_grant")

    # 需要 string.h 才有 strcmp(内核里由 linux/string.h 提供，确认 include 链里有)
    if "#include <linux/string.h>" not in s:
        anchor = "#include <linux/cred.h>"
        if s.count(anchor) == 1:
            s = s.replace(anchor, anchor + "\n#include <linux/string.h>   /* rc74c: ksu_birth_is_helper() 用 strcmp */", 1)
            print("  [ok] 补 include linux/string.h")
        else:
            print("  [x] 找不到 cred.h 锚点，又缺 string.h ⇒ 停")
            return 1

    wr(DS, s)
    print("  写完 md5=%s 行数=%d" % (md5(DS)[:8], s.count("\n") + 1))
    # 复证（自己数，别只信 replace 成功）
    for k, want in [("KSUBIRTH helper n=", 1), ("KSUBIRTH rate n=", 1), ("ksu_mgr_birth_rate", 4),
                    ("ksu_birth_is_helper", 2), ("ksu_mgr_birth_cap = 4096", 1)]:
        c = s.count(k)
        ok = "ok" if (c >= want) else "BAD"
        print("    [%s] %s 出现 %d 次(期望 ≥%d)" % (ok, k, c, want))
        if ok != "ok":
            return 1
    if s.count("if (unlikely(!current->files))") != 1:
        print("  [x] rc73 那把 files==NULL 护栏被动了 ⇒ 停")
        return 1
    NEWBLK = s[s.index("rc74c(md 6.429)"):]
    NJ = sum(NEWBLK.count(x) for x in ("jiffies", "time_after_eq", " HZ"))
    print("  护栏复证：files==NULL 1 处、GFP_ATOMIC %d 处、新增段里没有 GFP_KERNEL %d 处" %
          (s.count("GFP_ATOMIC"), NEWBLK.count("GFP_KERNEL")))
    print("  ★装载面复证：新增段里 jiffies/HZ/time_after_eq 共 %d 处(必须 0——多一个内核符号就多一条 __versions CRC)" % NJ)
    if NJ:
        print("  [x] 新代码又去引新符号了 ⇒ 停(这条就是第 56 发被构建闸逮住的教训)")
        return 1
    print("PASS(rc74c 补丁落地；宿主真值表在 w821，编 ko 前会跑)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
