#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""framecmp.py —— 比较两个构建里同一组函数的**栈帧大小**(prologue 的 `sub sp, sp, #imm`)。

为什么先做这个: 项目里 GhostLock 的卡点是"要覆盖深度 [0x288,0x298]，直连栈写通道上限约 0x210"，
  而那些数字是在 **另一个构建(gbfef221370b4)** 上量的。设备实际跑的是 g2a88cd145def。
  如果两构建的这些帧大小完全一致 ⇒ 旧结论可以直接沿用；只要有一个不一致 ⇒ 深度必须重算。
用法: python framecmp.py <函数名,逗号分隔>
"""
import io, re, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

BUILDS = [
    ("g2a88(设备)", r'G:\项目\Windows管理\usb\临时root\analysis\kallsyms_g2a88cd145def.txt',
     r'G:\项目\Windows管理\usb\临时root\analysis\kernel_dev_g2a88cd145def.bin'),
    ("gbfef(旧镜像)", r'G:\项目\Windows管理\usb\临时root\analysis\embedded-kallsyms.txt',
     r'G:\项目\Windows管理\usb\临时root\analysis\kernel'),
]
BASE = 0xffffffc010080000
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)

def load(ks):
    d = {}
    for line in io.open(ks, encoding='utf-8', errors='replace'):
        p = line.split()
        if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
            d.setdefault(p[2], int(p[0], 16))
    return d

def frames(img, names):
    data = io.open(img, 'rb').read()
    out = {}
    for nm in names:
        a = names[nm] if isinstance(nm, str) else None
        out[nm] = None
    return out

def main():
    want = sys.argv[1].split(',') if len(sys.argv) > 1 else []
    tabs = []
    for label, ks, img in BUILDS:
        d = load(ks)
        data = io.open(img, 'rb').read()
        res = {}
        for nm in want:
            if nm not in d:
                res[nm] = ('缺符号', None)
                continue
            a = d[nm]
            off = a - BASE
            if off < 0 or off + 80 > len(data):
                res[nm] = ('越界', None); continue
            # 帧 = 预索引压栈 `stp/str .., [sp, #-N]!` 之和 + 之后第一条 `sub sp, sp, #N`
            total = 0; got_sub = False; first = None; note = []
            for ins in md.disasm(data[off:off+120], a):
                if first is None: first = "%s %s" % (ins.mnemonic, ins.op_str)
                o = ins.op_str
                if ins.mnemonic in ('stp', 'stp', 'str') and re.search(r'\[sp, *#-0x([0-9a-f]+)\]!', o):
                    total += int(re.search(r'\[sp, *#-0x([0-9a-f]+)\]!', o).group(1), 16)
                    continue
                if ins.mnemonic == 'sub' and re.match(r'^sp,\s*sp,\s*#(0x[0-9a-f]+|\d+)$', o):
                    v = o.split('#')[1]
                    total += int(v, 16) if v.startswith('0x') else int(v)
                    got_sub = True
                    break
                if ins.mnemonic in ('bl', 'b'):
                    break
            res[nm] = (total if (got_sub or total) else None, first)
        tabs.append((label, res))
    print("%-38s %-22s %-22s %s" % ("函数", tabs[0][0], tabs[1][0], "首指令(设备构建)"))
    diff = 0
    for nm in want:
        f0 = tabs[0][1][nm][0]; f1 = tabs[1][1][nm][0]
        same = (f0 == f1)
        if not same: diff += 1
        def hx(v): return ("0x%x" % v) if isinstance(v, int) else str(v)
        print("%-38s %-22s %-22s %-28s %s" % (nm, hx(f0), hx(f1), str(tabs[0][1][nm][1])[:28],
                                              "" if same else "★不同"))
    print("不同的函数个数: %d / %d" % (diff, len(want)))

main()
