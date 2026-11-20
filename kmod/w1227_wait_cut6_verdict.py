#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 19 枪判据等待器：盯 exp10_deathbed.txt，判「活 ≥30 min」/「中途挂死」/「仪器不合格」。

见证格式（cut56 ko）：`SERD CUT56 cut=6 hits5=0 hits6=<N> quiet=0`
判据（w1226）：cut=6 逐字对上、hits6 单调>0、hits5 恒 0、活 ≥30 min 同一 boot、
             死前 ≥5 拍 mod=1 完整读数。死亡/存活时刻只用同源 up=。
"""
import re
import time

POLL = r"G:/项目/Windows管理/usb/临时root/kmod/w103_evidence/exp10_deathbed.txt"
PROG = r"G:/项目/Windows管理/usb/临时root/kmod/w103_evidence/exp10_verdict_progress.txt"
WALL_DEADLINE = time.time() + 2700  # 45 分钟硬顶


def rows():
    try:
        lines = open(POLL, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return [], []
    out = []
    for l in lines:
        m = re.search(r"up=([\d.]+)", l)
        if m:
            out.append((float(m.group(1)), l))
    return out, lines


def nums(lines, key):
    v = []
    for l in lines:
        m = re.search(key + r"=(\d+)", l)
        if m:
            v.append(int(m.group(1)))
    return v


verdict = "TIMEOUT"
note = ""
while time.time() < WALL_DEADLINE:
    r, lines = rows()
    mod1 = [(u, l) for u, l in r if re.search(r"\bmod=1\b", l)]
    first_up = mod1[0][0] if mod1 else None
    last_up = r[-1][0] if r else -1.0
    serd = [l for l in lines if "SERD CUT56" in l]
    died = any("连续 6 拍 OFFLINE" in l for l in lines)

    if died:
        verdict = "DIED"
        note = "第一拍 mod=1 up=%.2f → 最后读数 up=%.2f ⇒ 约 %.2f s；SERD 行=%d" % (
            first_up or -1, last_up, last_up - (first_up or last_up), len(serd))
        break
    if first_up is not None and last_up >= first_up + 1800:
        verdict = "SURVIVED_30MIN"
        note = "第一拍 mod=1 up=%.2f → 最后读数 up=%.2f ⇒ %.2f s；SERD 行=%d" % (
            first_up, last_up, last_up - first_up, len(serd))
        break

    h6 = nums(lines, "hits6")
    with open(PROG, "w", encoding="utf-8") as f:
        f.write("%s  first_mod1=%s  last_up=%.2f  alive=%s  mod1_poll=%d  serd=%d  hits6=%s\n" % (
            time.strftime("%F %T"),
            ("%.2f" % first_up) if first_up is not None else "-",
            last_up,
            ("%.2f" % (last_up - first_up)) if first_up is not None else "-",
            len(mod1), len(serd), h6[-1] if h6 else "-"))
    time.sleep(20)
else:
    note = "45 分钟硬顶到了，未达判据 ⇒ 判未测"

r, lines = rows()
mod1 = [(u, l) for u, l in r if re.search(r"\bmod=1\b", l)]
serd = [l for l in lines if "SERD CUT56" in l]
h6 = nums(lines, "hits6")
h5 = nums(lines, "hits5")
mono = all(h6[i] <= h6[i + 1] for i in range(len(h6) - 1)) if h6 else False
cut6_ok = all("cut=6" in l for l in serd) if serd else False
h5_zero = all(x == 0 for x in h5) if h5 else False
instrument = "OK" if (len(mod1) >= 5 and serd and h6 and h6[-1] > 0 and mono
                      and cut6_ok and h5_zero) else "INSUFFICIENT"
with open(PROG, "a", encoding="utf-8") as f:
    f.write("%s  VERDICT=%s  %s\n" % (time.strftime("%F %T"), verdict, note))
    f.write("  仪器: mod1 拍数=%d  SERD 行=%d  hits6 末值=%s  单调=%s  cut=6 全对=%s  hits5 恒0=%s ⇒ %s\n" % (
        len(mod1), len(serd), h6[-1] if h6 else "-", mono, cut6_ok, h5_zero, instrument))
print("VERDICT=%s %s | 仪器=%s" % (verdict, note, instrument))
