#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ksu_scan.py —— 把 KernelSU 源码里**实际解引用的字段名**列出来（路线 B 的"要量哪些字段"清单）。

为什么要它：padded header 只需要保证"KSU 真读写的字段"偏移正确。
所以先问 KSU 碰了哪些字段，再去对照设备实测表 —— 落在未夹细区间里的字段才是真缺口。
（远端跑：python3 /home/lucy/ksu_scan.py /root/k/ksu/kernel > /home/lucy/ksu_fields.txt）
"""
import os, re, sys, collections

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
ANY = re.compile(r"(?:->|\.)([a-zA-Z_][a-zA-Z_0-9]*)")
# task/cred 族变量的解引用(变量名靠内核惯例挑，宁可宽)
TASKLIKE = re.compile(
    r"\b(current|task|t|p|n|tt|tsk|cred|new_cred|old_cred|dc|nsproxy|files|fs|signal|sighand|"
    r"init_cred|prepare_kernel_cred|group_leader|real_parent|leader|suicide|worker|"
    r"thread|ti|thi)\s*(?:\(\))?\s*->\s*([a-zA-Z_][a-zA-Z_0-9]*)")

allc = collections.Counter()
tlc = collections.Counter()
per = collections.defaultdict(collections.Counter)
nf = 0
for dp, dn, fns in os.walk(ROOT):
    for f in fns:
        if not f.endswith((".c", ".h")):
            continue
        path = os.path.join(dp, f)
        try:
            txt = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        nf += 1
        rel = os.path.relpath(path, ROOT).replace("\\", "/")
        for m in ANY.finditer(txt):
            allc[m.group(1)] += 1
            per[rel][m.group(1)] += 1
        for m in TASKLIKE.finditer(txt):
            tlc[m.group(2)] += 1

print(f"# 扫了 {nf} 个 .c/.h (root={ROOT})")
print("\n# ==== A) task/cred 族变量 ->字段（这就是 KSU 真正读写 task_struct/cred 的清单）====")
for k, v in tlc.most_common(200):
    print(f"{v}\t{k}")
print("\n# ==== B) 全项目解引用字段名 top 200（对照用，含 file/inode/dentry 等）====")
for k, v in allc.most_common(200):
    print(f"{v}\t{k}")
print("\n# ==== C) 每个文件的主要 task 族字段（定位'谁依赖什么'）====")
for rel in sorted(per):
    hits = {k: v for k, v in per[rel].items() if k in tlc}
    if hits:
        print(f"{rel}: " + " ".join(f"{k}*{v}" for k, v in sorted(hits.items(), key=lambda r: -r[1])[:12]))
