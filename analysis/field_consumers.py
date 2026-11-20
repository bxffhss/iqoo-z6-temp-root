#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""别名追踪版"字段消费者"扫描: 给定一个静态地址, 找出全镜像里所有以它为基址的访存,
并传播 `add Xd, Xs, #imm` / `mov Xd, Xs`, 从而报告**相对目标地址的有效偏移**。
用途: 判断 `selinux_state` qword0 的 byte2..byte7 到底有没有人读 —— 决定我们能不能
往整个 8 字节写一个"低 16 位合适"的核地址(形状(2) 唯一能控制 byte0/byte1 的写法)。
用法: python field_consumers.py 0xffffffc012b18000 [max_disp_hex=20]
"""
import io, re, sys, collections, bisect
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

KS = r'G:\项目\Windows管理\usb\临时root\analysis\kallsyms_g2a88cd145def.txt'
IMG = r'G:\项目\Windows管理\usb\临时root\analysis\kernel_dev_g2a88cd145def.bin'
BASE = 0xffffffc010080000
TGT = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0xffffffc012b18000
MAXD = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x20
PAGE = TGT & ~0xfff

syms = []
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), ' '.join(p[2:])))
syms.sort()
addrs = [s[0] for s in syms]

def name_of(a):
    i = bisect.bisect_right(addrs, a) - 1
    return syms[i][1] if i >= 0 else '?'

data = io.open(IMG, 'rb').read()
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True

sites = []
for off in range(0, len(data) - 4, 4):
    ins = int.from_bytes(data[off:off + 4], 'little')
    if (ins & 0x9f000000) == 0x90000000:
        imm = (((ins >> 29) & 3) | (((ins >> 5) & 0x7ffff) << 2))
        if imm & (1 << 20):
            imm -= (1 << 21)
        if ((BASE + off) & ~0xfff) + (imm << 12) == PAGE:
            sites.append(off)

MEM = re.compile(r'^l(?:d|dr)|^st', re.A)
acc = collections.Counter()
detail = collections.defaultdict(list)

for h in sites:
    seq = list(md.disasm(data[h:h + 600], BASE + h))
    if not seq:
        continue
    state = {}
    r0 = seq[0].op_str.split(',')[0].strip()
    state[r0] = PAGE - TGT                 # 该寄存器 = 页首, 相对 TGT 的偏移
    for i in seq[1:]:
        mn, ops = i.mnemonic, i.op_str
        # ---- 1. 访存: [Xn, #imm] / [Xn] ----
        for m in re.finditer(r'\[(x|w)(\d+|zr)\s*(?:,\s*#(-?0x[0-9a-f]+|-?\d+))?\]', ops):
            reg = m.group(1) + m.group(2)
            if reg not in state:
                continue
            d = 0
            if m.group(3):
                s = m.group(3)
                d = int(s, 16) if 'x' in s else int(s)
            eff = state[reg] + d
            if abs(eff) <= MAXD:
                acc[(eff, mn)] += 1
                detail[eff].append('%x  %-9s %-34s in %s' % (i.address, mn, ops, name_of(i.address)))
        # ---- 2. add Xd, Xs, #imm ⇒ 传播 ----
        m = re.fullmatch(r'add\s+(x\d+),\s*(x\d+),\s*#(-?0x[0-9a-f]+|-?\d+)', ops)
        if m and m.group(2) in state:
            s = m.group(3)
            v = state[m.group(2)] + (int(s, 16) if 'x' in s else int(s))
            if abs(v) <= 0x2000:
                state[m.group(1)] = v
            else:
                state.pop(m.group(1), None)
            continue
        # ---- 3. mov Xd, Xs ⇒ 传播 ----
        m = re.fullmatch(r'mov\s+(x\d+),\s*(x\d+)', ops)
        if m and m.group(2) in state:
            state[m.group(1)] = state[m.group(2)]
            continue
        # ---- 4. 目标寄存器被改写 ⇒ 失效 ----
        m = re.match(r'^(?:[a-z][a-z0-9]*)\s+(x\d+|w\d+|zr)\b', ops)
        if m and m.group(1) in state and m.group(1) not in re.findall(r'\b(?:x|w)\d+\b', ops)[1:]:
            state.pop(m.group(1), None)

print('adrp 命中 %s 页 = %d 处' % (hex(TGT), len(sites)))
print('--- 相对 %s 的有效偏移 -> 访存 ---' % hex(TGT))
for (d, mn), c in sorted(acc.items()):
    print('  off %+5d (0x%02x)  %-8s x%d' % (d, d & 0xffff, mn, c))
print('--- 现场(每偏移最多 4 条) ---')
for d in sorted(detail):
    print(' off %+d (0x%x):' % (d, d & 0xffff))
    for l in detail[d][:4]:
        print('   ', l)
