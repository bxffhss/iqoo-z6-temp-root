#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ksu_coverage.py —— 拿 KSU 实际解引用的字段清单(kmod/layout/ksu_fields.txt)，
逐个落到 QC 树的偏移上，再按"**δ 阶梯已知区/未知区**"分类：
  已知 = 设备 = 树 + 56(头部 ti 区) 或 + 64(树 >= 984 的尾部) ⇒ 可以直接编
  未知 = 落在中段那条还没夹细的 +8 区间(树 132..984) ⇒ 必须先量出来才能编
这就是"路线 B 到底还差什么"的定量答案，而不是"等 vivo 源码"。
"""
import os, re, sys, collections

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import off_diff as O          # 复用同一套 pahole 解析(已验证过)

HERE = os.path.dirname(os.path.abspath(__file__))
TREE = "nothing_sm7325_v_mr"
HEAD_END = 132               # normal_prio 之后进入未知区
TAIL_START = 984             # sched_task_group 起 δ=+64 已被 29 条锚点证实

tbl = O.parse_pahole(os.path.join(HERE, "layout", f"layout2_{TREE}.txt"))
ts = tbl.get("task_struct", {})

# KSU 的 A) 段字段(去掉 file/inode/selinux 族的噪声)
TASK_FIELDS = set("""pid comm sighand seccomp fs files group_leader mm cred real_cred nsproxy
signal parent real_parent thread thread_info flags prio stack usage ptrace wake_entry
sched_task_group active_mm restart_block pi_blocked_on pi_lock pi_waiters pi_top_task
children sibling ptraced ptrace_entry thread_pid""".split())
CRED_FIELDS = set(tbl.get("cred", {}).keys())

want = []
started = False
for line in open(os.path.join(HERE, "layout", "ksu_fields.txt"), encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if line.startswith("# ==== A)"):
        started = True
        continue
    if line.startswith("# ==== B)"):
        break
    if started and "\t" in line:
        n, name = line.split("\t", 1)
        want.append((name, int(n)))

print(f"# 参照树 = {TREE}   未知区 = 树偏移 ({HEAD_END}, {TAIL_START})")
unk, known, other, missing = [], [], [], []
for name, n in want:
    if name in ts:
        offs = [o for o, s in ts[name]]
        o = max(offs)
        if HEAD_END < o < TAIL_START:
            unk.append((name, o, n))
        elif o <= HEAD_END:
            known.append((name, o, "+56(头部 ti 区)", n))
        else:
            known.append((name, o, "+64(尾部已 29 锚点证实)", n))
    elif name in CRED_FIELDS:
        other.append((name, "cred 里的字段", n))
    else:
        missing.append((name, n))

print(f"\n=== ① KSU 要读写的 task_struct 字段：**全部落在已知区**({len(known)} 个) ===")
for name, o, band, n in sorted(known, key=lambda r: r[1]):
    print(f"  {name:<20} 树{o:>6}  设备{o + (56 if '+56' in band else 64):>6}  {band:<26} KSU 里出现 {n} 次")
print(f"\n=== ② 落在**未知区**({HEAD_END}..{TAIL_START})的 task_struct 字段 = {len(unk)} 个 ===")
for name, o, n in sorted(unk, key=lambda r: r[1]):
    print(f"  {name:<20} 树{o:>6}  KSU 里出现 {n} 次  <== 必须先量")
if not unk:
    print("  (无)")
print(f"\n=== ③ 属于别的结构体(cred 等)，不受 task_struct δ 阶梯影响 ===")
print("  " + ", ".join(f"{nm}*{n}" for nm, _, n in other))
print(f"\n=== ④ 名字在 task_struct/cred 里都没有(= file/inode/dentry/selinux 族或局部结构) ===")
print("  " + ", ".join(f"{nm}*{n}" for nm, n in missing[:60]))

print(f"\n=== ⑤ cred 的字段有没有设备锚点？===")
dev = O.load_device(os.path.join(HERE, "device_offsets.txt"))
cred_dev = {k: v for k, v in dev.items() if k.startswith("cred.")}
print(f"  设备侧 cred.* 实测锚点: {len(cred_dev)} 个 " +
      ("⇒ **这是路线 B 现在最大的缺口**" if len(cred_dev) < 3 else ""))
print(f"  树里 cred 有 {len(CRED_FIELDS)} 个字段、sizeof={O.tree_sizeof(tbl,'cred')}；"
      f"KSU 用到其中 {len([1 for nm,_,n in other])} 个(见③)")
