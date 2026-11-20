#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 18 枪判据等待器：盯 exp9_deathbed.txt，判「活 ≥30 min」/「中途挂死」/「仪器不合格」。

判据（w1224 预登记）：
  1) 通道成立：有 `SERD CUT5` 行；
  2) 切口生效：hits 单调增长且 >0；
  3) 主判据：同一 boot 活 ≥30 min（同源 up=，不拿 epoch 夹）；
  4) 死前现场：至少 5 拍 `mod=1` 的完整读数。
死亡/存活时刻一律只用同源 up=；第一拍 mod=1 的 up 作装载近似（误差 <3 s）。
"""
import re
import time

POLL = r"G:/项目/Windows管理/usb/临时root/kmod/w103_evidence/exp9_deathbed.txt"
PROG = r"G:/项目/Windows管理/usb/临时root/kmod/w103_evidence/exp9_verdict_progress.txt"
WALL_DEADLINE = time.time() + 2700  # 45 分钟硬顶


def rows():
    try:
        lines = open(POLL, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return [], []
    out = []
    for l in lines:
        m = re.search(r"up=([\d.]+)", l)
        if not m:
            continue
        out.append((float(m.group(1)), l))
    return out, lines


def hits(lines):
    v = []
    for l in lines:
        m = re.search(r"hits=(\d+)", l)
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
    serd = [l for l in lines if "SERD CUT5" in l]
    died = any("连续 6 拍 OFFLINE" in l for l in lines)
    hv = hits(lines)

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

    with open(PROG, "w", encoding="utf-8") as f:
        f.write("%s  first_mod1=%s  last_up=%.2f  alive=%s  mod1_poll=%d  serd=%d  hits_last=%s\n" % (
            time.strftime("%F %T"),
            ("%.2f" % first_up) if first_up is not None else "-",
            last_up,
            ("%.2f" % (last_up - first_up)) if first_up is not None else "-",
            len(mod1), len(serd), hv[-1] if hv else "-"))
    time.sleep(20)
else:
    note = "45 分钟硬顶到了，未达判据 ⇒ 判未测"

# 仪器合格性（无论活死都要报）
r, lines = rows()
mod1 = [(u, l) for u, l in r if re.search(r"\bmod=1\b", l)]
serd = [l for l in lines if "SERD CUT5" in l]
hv = hits(lines)
mono = all(hv[i] <= hv[i + 1] for i in range(len(hv) - 1)) if hv else False
instrument = "OK" if (len(mod1) >= 5 and serd and hv and hv[-1] > 0 and mono) else "INSUFFICIENT"
with open(PROG, "a", encoding="utf-8") as f:
    f.write("%s  VERDICT=%s  %s\n" % (time.strftime("%F %T"), verdict, note))
    f.write("  仪器: mod1 拍数=%d  SERD 行=%d  hits 末值=%s  hits 单调=%s ⇒ %s\n" % (
        len(mod1), len(serd), hv[-1] if hv else "-", mono, instrument))
print("VERDICT=%s %s | 仪器=%s" % (verdict, note, instrument))
