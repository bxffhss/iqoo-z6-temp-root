#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w691_birth_test.py —— 在构建机上把 rc74b 的**判定函数原文**抠出来、用 gcc 编到宿主上跑真值表。
   跑法(远端)：python3 /home/lucy/w691_birth_test.py /root/k/ksu/kernel/infra/dev_syms.c
   为什么这样测(例 172 那条铁律：夹具不共用被测代码，它就只证明夹具自洽)：
     `ksu_birth_gate()` 写成**纯函数**(只有 int/struct 参数、不碰任何内核 API)，并被
     BEGIN/END KSUBIRTH-PURE 圈起来 ⇒ 本脚本从**打完补丁的那份文件**里逐字节抠出这段，
     原样贴进 harness 编译 ⇒ 跑的就是上机的那段字节，不是我在测试里重写的一份"逻辑等价"。
   ★负对照(这条决定测试有没有牙)：同一份负载(4 个 pid 交替 ×100 次)也喂给**手抄的 rc74 单槽逻辑**，
     它必须排 400 次，而 rc74b 必须只排 4 次 ⇒ 如果哪天断言只剩"看起来通过"，这条会先红。
   十格：去重／换 pid／**同 pid 但 start_time 变(必须再排，这是 pid 复用的初衷)**／非领头／
     uid 不命中／父进程同 uid(Manager 自己 fork 的子进程)／cap 兜底／环满腾位(腾最老出生的)／
     热路径对照(新=4、旧=400)／forget 回滚(分配失败不许永久拉黑)。
"""
import hashlib
import io
import os
import re
import subprocess
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel/infra/dev_syms.c"
W = "/home/lucy/w691_work"
PB, PE = "/* BEGIN KSUBIRTH-PURE */", "/* END KSUBIRTH-PURE */"

s = io.open(SRC, encoding="utf-8", errors="surrogateescape").read()
a, b = s.count(PB), s.count(PE)
if a != 1 or b != 1:
    print("[x] 标记命中 BEGIN=%d END=%d(应各 1)⇒ 抠不出原文，这发没测(不是通过)" % (a, b))
    sys.exit(1)
i0 = s.index(PB)
i1 = s.index(PE) + len(PE)
pure = s[i0:i1]
if len(pure) < 400 or "ksu_birth_gate" not in pure or "ksu_birth_forget" not in pure:
    print("[x] 抠出的段异常短/缺函数(len=%d)⇒ 停" % len(pure))
    sys.exit(1)
PM = hashlib.md5(pure.encode("utf-8", "surrogateescape")).hexdigest()[:8]
print("  抠出被测原文：len=%d 字节 md5=%s 行数=%d" % (len(pure), PM, pure.count(chr(10)) + 1))

if not os.path.isdir(W):
    os.makedirs(W)
io.open(os.path.join(W, "gate.inc"), "w", encoding="utf-8", newline="\n").write(pure + "\n")

HARNESS = r"""
#include <stdio.h>
#include <string.h>

#include "gate.inc"

/* 负对照：rc74 那份**单槽**去重(手抄自 kmod/w685_add_birthfd.py 的 BLOCK，形状一字不差) */
static int o_pid;
static unsigned long long o_start;
static int old_gate(int is_leader, int uid_ok, int parent_is_mgr, int pid, unsigned long long start)
{
	(void)parent_is_mgr;                 /* rc74 没有这一维 */
	if (!is_leader) return 2;
	if (!uid_ok) return 3;
	if (o_pid == pid && o_start == start) return 5;
	o_pid = pid; o_start = start;
	return 1;
}

static int fails;
static void chk(const char *name, int got, int want)
{
	int ok = (got == want);
	if (!ok) fails++;
	printf("CELL %-26s got=%d want=%d %s\n", name, got, want, ok ? "[OK]" : "[BAD]");
}
static void chkstr(const char *name, const char *got, const char *want)
{
	int ok = !strcmp(got, want);
	if (!ok) fails++;
	printf("CELL %-26s got=[%s] want=[%s] %s\n", name, got, want, ok ? "[OK]" : "[BAD]");
}

int main(void)
{
	struct ksu_birth_ent ring[16];
	int nr, total, cap = 64, r, i, acc;

	memset(ring, 0, sizeof(ring)); nr = 0; total = 0;

	/* T1 同一个 (pid,start) 连敲 5 次 ⇒ 只排 1 次，其余 4 次必须是 dup */
	acc = 0;
	for (i = 0; i < 5; i++) {
		r = ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 1, 0, 3560, 1169911130282ULL);
		if (r == 1) acc++;
		else chk("T1.dup.return", r, 5);
	}
	chk("T1.queue.once", acc, 1);
	chk("T1.total", total, 1);
	chk("T1.slots", nr, 1);

	/* T2 换 pid ⇒ 必须排 */
	r = ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 1, 0, 3561, 1170000000000ULL);
	chk("T2.new.pid", r, 1);

	/* T3 同 pid 但 start_time 变(pid 复用) ⇒ 必须再排(这条就是加 start_time 的理由) */
	r = ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 1, 0, 3561, 2000000000000ULL);
	chk("T3.pid.reuse.newstart", r, 1);

	/* T4 非线程组领头 ⇒ 2，且不许占槽 */
	r = ksu_birth_gate(ring, 16, &nr, &total, cap, 0, 1, 0, 9999, 3000ULL);
	chk("T4.not.leader", r, 2);
	chk("T4.total.unchanged", total, 3);

	/* T5 uid 不命中 ⇒ 3 */
	r = ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 0, 0, 9998, 3000ULL);
	chk("T5.uid.not.manager", r, 3);

	/* T6 父进程同一个 uid ⇒ Manager 自己 fork 的子进程，一律不排 ⇒ 4 */
	r = ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 1, 1, 13318, 1724956878195ULL);
	chk("T6.child.of.manager", r, 4);
	chk("T6.total.unchanged", total, 3);

	/* T7 cap 兜底：total 已到顶 ⇒ 6，不占槽 */
	total = cap;
	r = ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 1, 0, 40000, 4000ULL);
	chk("T7.cap", r, 6);
	total = 3;

	/* T9 环满(16 个各不相同)再来第 17 个 ⇒ 放行，且腾掉的必须是 start 最小(最老出生)的那个 */
	memset(ring, 0, sizeof(ring)); nr = 0; total = 0;
	for (i = 0; i < 16; i++) {
		r = ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 1, 0, 1000 + i, 100000ULL + i);
		if (r != 1) { printf("CELL T9.fill.step got=%d want=1 [BAD]\n", r); fails++; }
	}
	chk("T9.slots.full", nr, 16);
	r = ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 1, 0, 2000, 500000ULL);
	chk("T9.ringfull.allows.new", r, 1);
	chk("T9.slots.still", nr, 16);
	acc = 0;
	for (i = 0; i < 16; i++) if (ring[i].start == 100000ULL) acc++;
	chk("T9.evicted.oldest.born", acc, 0);

	/* T8 ★热路径对照：4 个 pid 交替 ×100 次(第 50 发的真实形状) */
	memset(ring, 0, sizeof(ring)); nr = 0; total = 0;
	acc = 0;
	for (i = 0; i < 400; i++) {
		int pid = 3560 + (i % 4);
		unsigned long long st = 1724956878195ULL + (i % 4);
		if (ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 1, 0, pid, st) == 1) acc++;
	}
	chk("T8.rc74b.exactly4", acc, 4);
	o_pid = 0; o_start = 0;
	acc = 0;
	for (i = 0; i < 400; i++) {
		int pid = 3560 + (i % 4);
		unsigned long long st = 1724956878195ULL + (i % 4);
		if (old_gate(1, 1, 0, pid, st) == 1) acc++;
	}
	chk("T8.rc74.control.must.flood", acc >= 100 ? 1 : 0, 1);
	printf("NOTE rc74_control_queued=%d rc74b_queued=%d\n", acc, 4);

	/* T10 forget：排过之后回滚(分配失败那条支) ⇒ 同一 (pid,start) 可以再排 */
	memset(ring, 0, sizeof(ring)); nr = 0; total = 0;
	r = ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 1, 0, 7777, 7777ULL);
	chk("T10.first", r, 1);
	r = ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 1, 0, 7777, 7777ULL);
	chk("T10.blocked", r, 5);
	ksu_birth_forget(ring, &nr, 7777, 7777ULL);
	r = ksu_birth_gate(ring, 16, &nr, &total, cap, 1, 1, 0, 7777, 7777ULL);
	chk("T10.after.forget", r, 1);
	chk("T10.slots", nr, 1);

	printf("SUMMARY fails=%d pure_md5=%s\n", fails, __PUREMD5__);
	return fails ? 1 : 0;
}
"""
io.open(os.path.join(W, "harness.c"), "w", encoding="utf-8", newline="\n").write(
    HARNESS.replace("__PUREMD5__", '"%s"' % PM))

c = ("cd %s && gcc -O1 -w -o ht harness.c 2>&1 && ./ht; echo HT_RC=$?" % W)
p = subprocess.run(["bash", "-lc", c], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
out = p.stdout.decode("utf-8", "replace")
print(out)

# ★期望值是一张**显式名单**(格名⇒该出现几次)，不是我拍的总数：
#   第一版我把门槛写成 n_ok>=26，而真产物 25 格 ⇒ 一个全绿的运行被我判红(例 173④同一族，这次栽在门槛上)。
EXPECT = {
    "T1.dup.return": 4, "T1.queue.once": 1, "T1.total": 1, "T1.slots": 1,
    "T2.new.pid": 1, "T3.pid.reuse.newstart": 1,
    "T4.not.leader": 1, "T4.total.unchanged": 1, "T5.uid.not.manager": 1,
    "T6.child.of.manager": 1, "T6.total.unchanged": 1, "T7.cap": 1,
    "T9.slots.full": 1, "T9.ringfull.allows.new": 1, "T9.slots.still": 1, "T9.evicted.oldest.born": 1,
    "T8.rc74b.exactly4": 1, "T8.rc74.control.must.flood": 1,
    "T10.first": 1, "T10.blocked": 1, "T10.after.forget": 1, "T10.slots": 1,
}
got = {}
bad = []
for m in re.finditer(r"CELL (\S+)\s+got=\S+\s+want=\S+\s+(\[[A-Z]+\])", out):
    nm, st = m.group(1), m.group(2)
    got[nm] = got.get(nm, 0) + 1
    if st != "[OK]":
        bad.append(nm + "=" + st)
missing = ["%s(实得 %d，应 %d)" % (k, got.get(k, 0), v) for k, v in EXPECT.items() if got.get(k, 0) != v]
ctrl = re.search(r"NOTE rc74_control_queued=(\d+) rc74b_queued=(\d+)", out)
if not ctrl:
    missing.append("负对照那行 NOTE 没出现(测试没有牙)")
elif int(ctrl.group(1)) < 100 or int(ctrl.group(2)) != 4:
    missing.append("负对照数字不对：rc74=%s rc74b=%s(应 >=100 与 =4)" % (ctrl.group(1), ctrl.group(2)))
if "HT_RC=0" not in out or "fails=0" not in out:
    missing.append("harness 自己的计数不是 0(HT_RC/fails)")
if missing or bad:
    print("[x] 逻辑测试没全绿 ⇒ 别编 ko，先修判定函数或修这张表：")
    for x in missing: print("    缺/错:", x)
    for x in bad: print("    红格:", x)
    sys.exit(1)
print("=== w691 完成：%d 格按名单逐格点名全 [OK](含负对照 rc74 单槽洪排 vs rc74b 只排 4)；被测原文 md5=%s ==="
      % (sum(EXPECT.values()), PM))
