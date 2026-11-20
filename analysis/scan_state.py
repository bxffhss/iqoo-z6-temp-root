#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""扫描 `selinux_state` 页的全部 adrp 引用, 打印其后 8 条指令里对该寄存器的访存偏移。
目的: 定出 struct selinux_state 每个 bool 的字节偏移(要往 +0 写 8 字节, 必须知道
      byte0 是 enabled 还是 initialized, 以及 +8/+0x10 是指针还是 bool 数组)。"""
import io, re, sys, collections
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

KS = r'G:\项目\Windows管理\usb\临时root\analysis\kallsyms_g2a88cd145def.txt'
IMG = r'G:\项目\Windows管理\usb\临时root\analysis\kernel_dev_g2a88cd145def.bin'
BASE = 0xffffffc010080000
TGT = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0xffffffc012b18000
PAGE = TGT & ~0xfff

syms = []
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), ' '.join(p[2:])))
syms.sort()
addrs = [s[0] for s in syms]

def name_of(a):
    import bisect
    i = bisect.bisect_right(addrs, a) - 1
    return syms[i][1] if i >= 0 else '?'

data = io.open(IMG, 'rb').read()
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True

hits = []
off = 0
end = len(data) - 4
while off < end:
    ins = int.from_bytes(data[off:off+4], 'little')
    if (ins & 0x9f000000) == 0x90000000:
        immlo = (ins >> 29) & 3
        immhi = (ins >> 5) & 0x7ffff
        imm = ((immhi << 2) | immlo)
        imm -= (1 << 21) if imm & (1 << 20) else 0
        ad = ((BASE + off) & ~0xfff) + (imm << 12)
        if ad == PAGE:
            hits.append(off)
    off += 4

print('adrp 引用 %s 处 = %d' % (hex(TGT), len(hits)))
offs = collections.Counter()
for h in hits:
    pc = BASE + h
    seq = list(md.disasm(data[h:h+40], pc))
    if not seq:
        continue
    a0 = seq[0]
    m = re.match(r'x(\d+)|w(\d+)', a0.op_str.split(',')[0])
    reg = a0.op_str.split(',')[0]
    lines = []
    for i in seq:
        t = i.mnemonic
        if re.search(r'\[%s(?:,|#)' % re.escape(reg), i.op_str) or \
           re.search(r'\[%s\]' % re.escape(reg), i.op_str) or \
           ('add' == t and reg in i.op_str):
            mm = re.search(r'#(0x[0-9a-f]+)', i.op_str)
            d = int(mm.group(1), 16) if mm else 0
            offs[(t.split('.')[0], d)] += 1
            lines.append('    %x: %-8s %s' % (i.address, i.mnemonic, i.op_str))
    if lines:
        print('  @ %x  in %s' % (pc, name_of(pc)))
        for l in lines[:4]:
            print(l)

print('--- 偏移直方图 (mnemonic, disp) ---')
for (t, d), c in sorted(offs.items(), key=lambda kv: kv[0][1]):
    print('  +0x%-4x  %-8s x%d' % (d, t, c))
