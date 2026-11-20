#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""task_anchors_from_rela.py —— 把 init_task 里**每一个**静态初始化的指针字段都变成设备实测锚点。

为什么：路线 B 需要"设备上的 struct 布局"。裸 Image 里 .data 的指针全是 0，
但镜像保留了 R_AARCH64_RELATIVE(.rela) 表：dest = 运行时被写的地址，addend = 链接期绝对值。
init_task 的指针字段(parent/cred/nsproxy/files/se/rb/…)**每一个**都有 rela 记录 ⇒
一条记录 = 一个实测偏移，不用猜、不用等厂商源码。

用法：python kmod/task_anchors_from_rela.py [符号名=init_task] [长度=0x1000]
输出：每行 `十进制偏移  0x十六进制  指向的符号` ⇒ 拿去和 pahole 的字段表对顺序。
"""
import sys, os, re, bisect

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "analysis"))
import dump_obj as D   # 复用已验证过的镜像/符号/rela 装载

TARGET = sys.argv[1] if len(sys.argv) > 1 else "init_task"
SPAN = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x1000

# 1. 目标对象的链接期地址
hit = [a for a, t, n in D.syms if n == TARGET]
if not hit:
    print(f"kallsyms 里找不到 {TARGET}")
    sys.exit(1)
base = hit[0]
print(f"# {TARGET} = {base:#x}  ({D.name_of(base)})  扫 {SPAN:#x} 字节")
rela = D.load_rela()

# 2. 精确符号名(不带 +0x 尾巴) —— 锚点要的是"这个字段指向谁的开头"
exact = {a: n for a, t, n in D.syms}


def sym_of(a):
    if a in exact:
        return exact[a]
    i = bisect.bisect_right(D.addrs, a) - 1
    if i < 0:
        return f"{a:#x}?"
    nm, ty, off = D.syms[i][2], D.syms[i][1], a - D.syms[i][0]
    return f"{nm}+{off:#x}"


n = 0
for dest in sorted(rela):
    if not (base <= dest < base + SPAN):
        continue
    off = dest - base
    addend = rela[dest]
    print(f"{off:<6} {off:#06x}  -> {sym_of(addend)}  ({addend:#x})")
    n += 1
print(f"# 共 {n} 条 rela 锚点")
