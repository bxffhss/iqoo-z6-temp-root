#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc26：把"进了调度器但没到 sucompat"这一格也照亮（md §6.46）。

第二十三发(rc25，限流已开)读回来的链条是：
    F(has_hook=1) 有  →  F2 redirect 有  →  ???  →  子进程拿到真 ENOENT
  E1/E2/E3/E4 = 0、SD4/SD5/SU0 = 0，而 SD1 只印了 uid=0 的那些 ⇒
  ① `KSUBEAT B dispatcher entered` 是 **pr_info_once**：一发只印一次，前面 uid 0 的风暴把它用掉了，
     于是"17174 那次进没进调度器"**没有判据**；
  ② SD1 我当初为防刷屏加了 `if (uid < 10000)` 的前置条件 ⇒ **恰好把 uid=10284 那一例筛掉了**
     （那一例正是"名单被 prune 删光 ⇒ 静默放弃"）。判据带筛子 = 自己把关键案例吃掉。

⇒ 三处最小改动，全部用**单行唯一锚点**（多行锚点我这次先失手过一次，别再靠它）：
  ① 调度器入口加一条每次都印的 `KSUBEAT BN`；
  ② SD1 的前置条件去掉（改成 `if (1)`），保留原打印；
  ③ 紧跟其后加一条 `KSUBEAT SD6 名单命中=` —— `ksu_is_allow_uid()` 的返回值就是
     "prune 之后名单里还剩谁"的最直接探针。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"

JOBS = [
    (M + "/hook/arm64/syscall_hook.c", "KSUBEAT BN",
     "    int orig_nr = (int)PT_REGS_ORIG_SYSCALL(regs);\n",
     '    pr_info("KSUBEAT BN dispatcher entered: syscallno=%d stash=%d pid=%d comm=%s\\n",\n'
     '            regs->syscallno, (int)PT_REGS_ORIG_SYSCALL(regs), current->pid, current->comm);\n'
     "    int orig_nr = (int)PT_REGS_ORIG_SYSCALL(regs);\n"),

    (M + "/feature/sucompat.c", "if (1) /* 6.46",
     "        if (current_uid().val < 10000)\n",
     "        if (1) /* 6.46：判据不许带筛子，无条件印 */\n"),

    (M + "/feature/sucompat.c", "KSUBEAT SD6",
     "                    current_uid().val);\n        goto do_orig_execve;\n",
     '                    current_uid().val);\n'
     '        pr_info("KSUBEAT SD6 名单命中=%d uid=%u\\n",\n'
     "                ksu_is_allow_uid(current_uid().val) ? 1 : 0, current_uid().val);\n"
     '        goto do_orig_execve;\n'),
]

n = 0
for path, probe, old, new in JOBS:
    s = io.open(path, encoding="utf-8", errors="replace").read()
    if probe in s:
        print("  = 已有, 跳过 %s (%s)" % (probe, path.split("/")[-1]))
        continue
    c = s.count(old)
    if c != 1:
        print("  !! 锚点在 %s 命中 %d 次, 不动: %r" % (path.split("/")[-1], c, old[:60]))
        continue
    io.open(path, "w", encoding="utf-8", newline="\n").write(s.replace(old, new, 1))
    n += 1
    print("  + %s (%s)" % (probe, path.split("/")[-1]))
print("写了 %d 处" % n)
