#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 17 枪判据等待器：盯 exp8c_once_poll.txt，判「活 ≥30 min」还是「中途掉线」。

为什么要单独一支：主判据是 30 分钟同一 boot，而人手轮询会漏掉中途掉线；
poll 脚本自己会在连续 6 拍 OFFLINE 后写收工行并退出，这里直接盯那一行。
死亡/存活时刻一律只用同源 up=（insmod up=670.13），不拿 PC epoch 夹。
"""
import re
import time
import os

POLL = r"G:/项目/Windows管理/usb/临时root/kmod/w103_evidence/exp8c_once_poll.txt"
PROG = r"G:/项目/Windows管理/usb/临时root/kmod/w103_evidence/exp8c_verdict_progress.txt"
INSMOD_UP = 670.13
TARGET_UP = INSMOD_UP + 1800.0      # 2470.13 = 活满 30 分钟
WALL_DEADLINE = time.time() + 2700  # 45 分钟硬顶


def read_lines():
    try:
        with open(POLL, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def ups(lines):
    out = []
    for l in lines:
        m = re.search(r"up=([\d.]+)", l)
        if m and "SERD" in l:
            out.append(float(m.group(1)))
    return out


verdict = "TIMEOUT"
while time.time() < WALL_DEADLINE:
    lines = read_lines()
    u = ups(lines)
    last_up = u[-1] if u else -1.0
    # poll 脚本判死后会写这行（只有见过 mod=1 才会写，见 w1219 的收工条件）
    died = any("连续 6 拍 OFFLINE" in l for l in lines)
    if died:
        verdict = "DIED"
        note = "死亡前最后 SERD up=%.2f（insmod 后 %.2f s）" % (last_up, last_up - INSMOD_UP)
        break
    if last_up >= TARGET_UP:
        verdict = "SURVIVED_30MIN"
        note = "最后 SERD up=%.2f（insmod 后 %.2f s，>1800）" % (last_up, last_up - INSMOD_UP)
        break
    with open(PROG, "w", encoding="utf-8") as f:
        f.write("%s  alive=%.2fs  last_up=%.2f  serd=%d  target=%.2f\n" % (
            time.strftime("%F %T"), last_up - INSMOD_UP, last_up, len(u), TARGET_UP))
    time.sleep(20)
else:
    note = "45 分钟硬顶到了，未达 30 分钟存活判据 ⇒ 判未测"

with open(PROG, "a", encoding="utf-8") as f:
    f.write("%s  VERDICT=%s  %s\n" % (time.strftime("%F %T"), verdict, note))
print("VERDICT=%s %s" % (verdict, note))
