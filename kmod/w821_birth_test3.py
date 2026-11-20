#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w821_birth_test3.py —— rc74c：把 dev_syms.c 里那段 **纯判定**原样抠到宿主上跑真值表（编 ko 之前）。
   跑法：python3 /home/lucy/w821_birth_test3.py /root/k/ksu/kernel/infra/dev_syms.c
   ★为什么必须抠原文而不是抄一份：例 172 一手——夹具自己抄代码就只能证明夹具自洽。
   ★判据设计：每个"挡住"都配一条**只差这一个条件**的对照(例 174/175：期望值不许是我拍的)。
     靶子一(8/9 格)＝helper：同一 pid/同一时刻，只差 comm ⇒ 7 vs 1。
     靶子二(10/11 格)＝上限：65 个不同 pid，cap=64 时第 65 个必须 6(＝第 56 发那台机器的形状)，cap=4096 必须 1。
     靶子三(12~17 格)＝速率：用事件自带的 start_time(ns) 当时钟，间隔内必须 8、跨过间隔必须 1、interval=0 必须整个关掉。
   ★22 格是我自己踩过的：腾位是**原地覆盖最老那一格**，不会把数组前移——第一版把期望写成 {200,300} 被判红，
     错的是期望不是代码(例 175 那一族)。
"""
import io
import os
import re
import subprocess
import sys
import tempfile

SRC = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel/infra/dev_syms.c"
s = io.open(SRC, encoding="utf-8", errors="surrogateescape").read()
m = re.search(r"/\* BEGIN KSUBIRTH-PURE \*/.*?/\* END KSUBIRTH-PURE \*/", s, re.S)
if not m:
    print("[x] 抠不到 KSUBIRTH-PURE 区 ⇒ 补丁没落地，停")
    sys.exit(1)
pure = m.group(0)
for want in ("ksu_birth_is_helper", "interval_ns", "last_grant"):
    if want not in pure:
        print("[x] PURE 区里找不到 %s ⇒ 这份还是 rc74b(或补丁没打全)，停" % want)
        sys.exit(1)
print("=== W821 宿主真值表(rc74c) 抠出 %d 字节纯代码；helper=%d interval=%d last_grant=%d ===" %
      (len(pure), pure.count("ksu_birth_is_helper"), pure.count("interval_ns"), pure.count("last_grant")))

MAIN = r"""
static int fails;
static void ck(const char *what, int got, int want)
{
	if (got == want)
		printf("  [OK] %-62s = %d\n", what, got);
	else {
		printf("  [BAD] %-62s = %d (期望 %d)\n", what, got, want);
		fails++;
	}
}

static struct ksu_birth_ent ring[16];
static int ring_nr, total;
static unsigned long long LAST;            /* 上一次放行的 start_time(ns)，测试自己推进 */
static unsigned long long INTERVAL = 125000000ULL;   /* 8 次/秒 */

static int g(int leader, int uid_ok, int parent_is_mgr, const char *comm, int cap,
	     int pid, unsigned long long start)
{
	int r = ksu_birth_gate(ring, 16, &ring_nr, &total, cap, leader, uid_ok, parent_is_mgr,
			       ksu_birth_is_helper(comm), LAST, INTERVAL, pid, start);
	if (r == 1 && start >= LAST)
		LAST = start;
	return r;
}
static void reset(void)
{
	int i;
	for (i = 0; i < 16; i++) { ring[i].pid = 0; ring[i].start = 0; }
	ring_nr = 0; total = 0; LAST = 0;
}

int main(void)
{
	printf("  —— helper 名单(全部来自第 56 发一手 comm) ——\n");
	ck("1  is_helper(libksud.so)=1", ksu_birth_is_helper("libksud.so"), 1);
	ck("2  is_helper(crash_dump64)=1", ksu_birth_is_helper("crash_dump64"), 1);
	ck("3  is_helper(debuggerd64)=1", ksu_birth_is_helper("debuggerd64"), 1);
	/* ★这三条不许省：第 51 发实测主进程排队时 comm 就是 usap64；sh/id 也是 Manager 一家常见的名字。
	   一旦被误列进 helper，被挡掉的正是我们要保护的那个进程。 */
	ck("4  is_helper(usap64)=0(必须放行)", ksu_birth_is_helper("usap64"), 0);
	ck("5  is_helper(sh)=0", ksu_birth_is_helper("sh"), 0);
	ck("6  is_helper(id)=0", ksu_birth_is_helper("id"), 0);

	reset();
	ck("7  领头+manager uid+非 helper ⇒ 排队(1)", g(1, 1, 0, "usap64", 4096, 100, 1000000000ULL), 1);
	ck("8  同一 (pid,start) 第二次 ⇒ 已排过(5)", g(1, 1, 0, "usap64", 4096, 100, 1000000000ULL), 5);
	/* ★9 必须跨过速率间隔再问：同一 pid 但 start 不同＝pid 被回收再用，语义上算新进程 */
	ck("9  pid 同但 start 不同(回收再用，且已过 1 秒) ⇒ 允许再排(1)", g(1, 1, 0, "usap64", 4096, 100, 2000000000ULL), 1);
	reset();
	ck("10 非领头 ⇒ 2", g(0, 1, 0, "x", 4096, 1, 1ULL), 2);
	ck("11 非 manager uid ⇒ 3", g(1, 0, 0, "x", 4096, 1, 1ULL), 3);
	ck("12 是 Manager 自己 fork 的(父同 uid) ⇒ 4", g(1, 1, 1, "x", 4096, 1, 1ULL), 4);

	/* 靶子一：只差 comm */
	reset();
	ck("13 libksud.so(领头、父已脱离、manager uid) ⇒ helper(7)",
	   g(1, 1, 0, "libksud.so", 4096, 500, 5000ULL), 7);
	ck("14 helper 被挡时不占预算、不占格：total=0 且 ring_nr=0", (total == 0 && ring_nr == 0) ? 1 : 0, 1);
	ck("15 同一条输入只差 comm ⇒ 1(对照：挡住的原因确实是 helper 名单)",
	   g(1, 1, 0, "usap64", 4096, 500, 5000ULL), 1);

	/* 靶子二：上限 */
	reset();
	{
		int i;
		for (i = 0; i < 64; i++)
			g(1, 1, 0, "mgr", 64, 1000 + i, 10000000000ULL + (unsigned long long)i * 200000000ULL);
		ck("16 cap=64：第 65 个不同 pid ⇒ 上限(6)",
		   g(1, 1, 0, "mgr", 64, 1064, 10000000000ULL + 64ULL * 200000000ULL), 6);
		ck("17 同一条输入只差 cap=4096 ⇒ 1(＝第 56 发那一步被修掉)",
		   g(1, 1, 0, "mgr", 4096, 1064, 10000000000ULL + 65ULL * 200000000ULL), 1);
	}

	/* 靶子三：速率(拿事件自带的 ns 当时钟) */
	reset();
	ck("18 首次放行(last_grant=0 视作没有上一次) ⇒ 1",
	   g(1, 1, 0, "mgr", 4096, 1, 1000000000ULL), 1);
	ck("19 50ms 后来第二个 ⇒ 间隔内(8)", g(1, 1, 0, "mgr", 4096, 2, 1050000000ULL), 8);
	ck("20 被速率挡下的不占预算：total 仍 1", total, 1);
	ck("21 跨过 200ms 的第三个 ⇒ 1", g(1, 1, 0, "mgr", 4096, 3, 1200000000ULL), 1);
	INTERVAL = 0;
	ck("22 interval=0 ⇒ 速率闸整个关掉(同一纳秒也放行)",
	   (reset(), g(1, 1, 0, "mgr", 4096, 4, 7ULL)), 1);
	INTERVAL = 125000000ULL;
	ck("23 时钟倒退(start<last_grant) ⇒ 放行，绝不把闸锁死",
	   g(1, 1, 0, "mgr", 4096, 5, 1ULL), 1);

	/* 环回收与失败回滚 */
	{
		struct ksu_birth_ent r2[2];
		int nr = 0, tt = 0;
		r2[0].pid = r2[1].pid = 0; r2[0].start = r2[1].start = 0;
		ck("24 环 2 格：第 1 个 ⇒ 1",
		   ksu_birth_gate(r2, 2, &nr, &tt, 4096, 1, 1, 0, 0, 0, 0, 11, 100ULL), 1);
		ck("25 第 2 个 ⇒ 1", ksu_birth_gate(r2, 2, &nr, &tt, 4096, 1, 1, 0, 0, 0, 0, 12, 200ULL), 1);
		ck("26 环满时第 3 个仍放行(1)，格数不涨",
		   (ksu_birth_gate(r2, 2, &nr, &tt, 4096, 1, 1, 0, 0, 0, 0, 13, 300ULL) == 1 && nr == 2) ? 1 : 0, 1);
		ck("27 腾的是最老那格(原地覆盖，不前移)",
		   (r2[0].start != 100ULL && r2[1].start != 100ULL) ? 1 : 0, 1);
		printf("      【现数】环两格现在＝{%llu,%llu}(第一版我把期望写成 {200,300}——原地覆盖不前移，错的是期望)\\n",
		       r2[0].start, r2[1].start);
		ck("28 分配失败 ⇒ forget 还格", (ksu_birth_forget(r2, &nr, 12, 200ULL), nr == 1) ? 1 : 0, 1);
		ck("29 forget 不存在的条目不弄坏状态", (ksu_birth_forget(r2, &nr, 999, 9ULL), nr == 1) ? 1 : 0, 1);
	}
	reset();
	ck("30 非领头 + comm=libksud.so ⇒ 2(领头判定在 helper 之前，挡的原因要说得清)",
	   g(0, 1, 0, "libksud.so", 4096, 1, 1ULL), 2);
	reset();
	ck("31 非 manager uid + comm=libksud.so ⇒ 3", g(1, 0, 0, "libksud.so", 4096, 1, 1ULL), 3);

	printf(fails ? "FAIL(%d 格红)\n" : "PASS(31 格全绿)\n", fails);
	return fails ? 1 : 0;
}
"""

C = "#include <stdio.h>\n#include <string.h>\n#include <stdlib.h>\n" + pure + MAIN
d = tempfile.mkdtemp(prefix="w821_")
cf = os.path.join(d, "t.c")
io.open(cf, "w", encoding="utf-8").write(C)
exe = os.path.join(d, "t")
r = subprocess.run(["gcc", "-O0", "-Wall", "-o", exe, cf], capture_output=True, text=True)
if r.returncode != 0:
    print("[x] 抠出来的纯判定段在宿主上编不过 ⇒ 补丁有问题：\n" + (r.stderr or "")[:2500])
    sys.exit(1)
if r.stderr.strip():
    print("  gcc 警告(不致命，但要看得懂)：\n" + r.stderr[:900])
p = subprocess.run([exe], capture_output=True, text=True)
print(p.stdout)
if p.stderr.strip():
    print("  stderr: " + p.stderr[:600])
print("退出码=%d" % p.returncode)
print("=== W821 %s ===" % ("PASS" if p.returncode == 0 else "FAIL"))
sys.exit(p.returncode)
