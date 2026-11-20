#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""analyze_killscan.py —— 用「时序对齐」定位 rc82_kp 第 1 发的死亡点。
   对照：成功窗口 w421_*.gz 里 KILLSCAN → KSUFDINST 的正常序列。
   只读本地归档，不碰设备、不碰远端。
"""
import glob, gzip, io, os, re

EV = r"G:/项目/Windows管理/usb/临时root/kmod/w103_evidence"
KEYS = ("KILLSCAN", "KILLGUARD", "KSUFDINST", "KSUSTEP 9", "KSUKEEP",
        "KSUSTEP", "Crowning", "KSUDEV", "Kernel panic", "Oops", "Call trace")


def load(path):
    op = gzip.open if path.endswith(".gz") else io.open
    with op(path, "rt", encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def pick(lines, keys=KEYS):
    return [l for l in lines if any(k in l for k in keys)]


print("=" * 78)
print("A. 本发 rc82kp_dmesg2.log")
print("=" * 78)
p = os.path.join(EV, "rc82kp_dmesg2.log")
L = load(p)
print("总行数:", len(L))
ks = [l for l in L if "KILLSCAN" in l or "KILLGUARD" in l]
print("KILLSCAN/KILLGUARD 条数:", len(ks))
print("--- 首次 5 条 ---")
for l in ks[:5]:
    print("   ", l[:220])
print("--- 末次 10 条 ---")
for l in ks[-10:]:
    print("   ", l[:220])
print("--- 关键事件（KSUSTEP9 / KSUFDINST / KSUKEEP / panic）全量 ---")
for l in L:
    if any(k in l for k in ("KSUSTEP 9", "KSUFDINST", "KSUKEEP", "Kernel panic",
                            "Oops", "Call trace", "Crowning manager")):
        print("   ", l[:220])
print("--- 末 30 行原文 ---")
for l in L[-30:]:
    print("   ", l[:220])

print()
print("=" * 78)
print("B. 成功窗口基线：KILLSCAN 序列与 KSUFDINST 时刻")
print("=" * 78)
gzs = sorted(glob.glob(os.path.join(EV, "w421_*dmesg_full*.gz")))
print("候选 gz:", len(gzs))
for g in gzs[-8:]:
    try:
        G = load(g)
    except Exception as e:
        print("  !! %s : %s" % (os.path.basename(g), e))
        continue
    hit = [l for l in G if ("KILLSCAN enter" in l or "KSUFDINST" in l
                            or "KSUSTEP 9" in l or "KSUKEEP" in l)]
    if not hit:
        continue
    print("\n>>> %s (%d 行)" % (os.path.basename(g), len(G)))
    for l in hit[:8]:
        print("   ", l[:230])
    if len(hit) > 8:
        print("    ... 共 %d 条，末 4 条：" % len(hit))
        for l in hit[-4:]:
            print("   ", l[:230])

print()
print("=" * 78)
print("C. 时序差（本发 vs 基线）")
print("=" * 78)


def ts(line):
    m = re.search(r"\[\s*([\d.]+)\]", line)
    return float(m.group(1)) if m else None


mine = {}
for l in L:
    if "KSUSTEP 9" in l and "s9" not in mine:
        mine["s9"] = ts(l)
    if "KILLSCAN enter" in l and "kill" not in mine:
        mine["kill"] = ts(l)
    if "KSUFDINST" in l and "fd" not in mine:
        mine["fd"] = ts(l)
    if "Crowning manager" in l and "crown" not in mine:
        mine["crown"] = ts(l)
print("本发:", mine, " 日志末行 t=", ts(L[-1]) if L else None)

# 最近的一个成功窗口做基线
for g in reversed(gzs):
    G = load(g)
    base = {}
    for l in G:
        if "KSUSTEP 9" in l and "s9" not in base:
            base["s9"] = ts(l)
        if "KILLSCAN enter" in l and "kill" not in base:
            base["kill"] = ts(l)
        if "KSUFDINST" in l and "fd" not in base:
            base["fd"] = ts(l)
    if base.get("s9") and base.get("fd"):
        print("基线(%s):" % os.path.basename(g), base)
        print("  KSUSTEP9 → KILLSCAN enter = %.3fs" % (base["kill"] - base["s9"]) if base.get("kill") else "  (无 KILLSCAN enter)")
        print("  KILLSCAN enter → KSUFDINST = %.3fs" % (base["fd"] - base["kill"]) if base.get("kill") else "")
        print("  KSUSTEP9 → KSUFDINST = %.3fs" % (base["fd"] - base["s9"]))
        break
