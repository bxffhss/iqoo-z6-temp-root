#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一发一份的读数器：吃死前全量 dmesg，吐固定几行判据。

为什么要有它：Exp-6/6b/6d/6e/6f 每发都是同一套读数（装载时刻、断流时刻、SD1 次数与速率、
NOSLOW/RATE 见证、崩溃签名），手敲每次都要重新拼正则、每次都可能换一个口径。
这里把口径钉死，只认：`[  up.ffffff]` 前缀（同源 up，跨 boot 不可比）。

用法：python w430_shot_report.py kmod/w103_evidence/exp6f_dmesg2.log [--probe 文件...]
     --probe 可以给 stage/punch 等旁证文件，只统计关键计数，不做时序。

判据口径（写死，不随发次改）：
  T_load  = 第一条含 "KernelSU:" 的行（模块 init 必然最先打印）
  T_death = 最后一条带 [up] 的行（PMIC 硬复位前的最后一行）
  存活    = T_death - T_load（这是"日志存活"，不是自然寿命；主动收口的发次必须另注）
"""
import sys, re, collections

SIG = ("panic", "Oops", "Call trace", "BUG:", "watchdog", "soft lockup",
       "scheduling while atomic", "Unable to handle", "Out of memory", "rcu_sched")
CLASSES = ("NOSLOW", "RATE ctr=", "CUT1 hit=", "SD0 decline", "SD1 decline", "SD2 decline",
           "SD3 decline", "SD5 do_orig_execve", "SU0 su found")
UP_RE = re.compile(r"^\[\s*(\d+\.\d+)\]")


def up_of(line):
    m = UP_RE.match(line)
    return float(m.group(1)) if m else None


def report(path):
    raw = open(path, encoding="utf-8", errors="replace").read()
    lines = [l for l in raw.split("\n") if l.strip()]
    timed = [(up_of(l), l) for l in lines if up_of(l) is not None]
    print("=== %s  (行数 %d，带时间戳 %d) ===" % (path, len(lines), len(timed)))
    if not timed:
        print("  !! 没有带 [up] 的行，拒绝判读")
        return

    ksu = [(u, l) for u, l in timed if "KernelSU:" in l]
    if ksu:
        print("  T_load  = %.3f   %s" % (ksu[0][0], ksu[0][1][:90]))
    else:
        print("  !! 本文件里没有任何 KernelSU 行 ⇒ 模块没装载/或抓取窗口不含装载期")
    print("  T_last  = %.3f   %s" % (timed[-1][0], timed[-1][1][:90]))
    if ksu:
        print("  日志存活= %.3f s" % (timed[-1][0] - ksu[0][0]))

    print("  --- 类计数 ---")
    for k in CLASSES:
        n = sum(l.count(k) for _, l in timed)
        if n:
            print("    %-20s %d" % (k, n))
    sd = [l for _, l in timed if "SD1 decline" in l]
    if sd:
        uid = collections.Counter((re.search(r"uid=(\d+)", l) or [None, "?"])[1] for l in sd)
        span = [u for u, l in timed if "SD1 decline" in l]
        print("    SD1 uid 分布        %s  速率=%.1f 次/s" % (dict(uid), len(span) / max(1e-9, span[-1] - span[0])))
    print("  --- 见证原文（全打，条数少）---")
    for u, l in timed:
        if ("NOSLOW hit=" in l) or ("RATE ctr=" in l) or ("CUT1 hit=" in l):
            print("    %.3f %s" % (u, l[:120]))
    print("  --- 崩溃签名（全 0 才是硬挂死的形状）---")
    hits = {k: sum(l.count(k) for _, l in timed) for k in SIG}
    print("    " + "  ".join("%s=%d" % (k, v) for k, v in hits.items()))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        raise SystemExit("用法：python w430_shot_report.py <dmesg 文件> [more...]")
    for p in args:
        report(p)
        print()
