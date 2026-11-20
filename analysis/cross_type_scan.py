#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 analysis/ 的 CFI 同类型表做一次"跨全类型"扫描:
   对**每一条**同类型表(14257 张), 把表里每个函数反汇编前 ~40 条指令,
   找这种形状:  `ldr x?, [x?, #K1]`  →  `ldr x?, [x?, #K2]`  →  `add`  →  `bl .(c|v)opy_from_user|copy_to_user`
   即"把某结构体字段当数据指针去搬用户数据" —— 这就是我们要的"任意地址读写"入口。
   输出: 命中清单(函数 + 它属于哪张类型表 ⇒ 哪个槽位能用)。
用法: python cross_type_scan.py            # 慢(全表), 建议加 --limit
"""
import io, os, re, sys, collections
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

KS = r'G:\项目\Windows管理\usb\临时root\analysis\kallsyms_g2a88cd145def.txt'
IMG = r'G:\项目\Windows管理\usb\临时root\analysis\kernel_dev_g2a88cd145def.bin'
TB = r'G:\项目\Windows管理\usb\临时root\analysis\cfi_type_tables.txt'
BASE = 0xffffffc010080000

syms = {}
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms[' '.join(p[2:])] = int(p[0], 16)
data = io.open(IMG, 'rb').read()
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True

# 表解析: 每张表 = 若干行成员 + 结束标志
tables = []            # (label, [names])
cur, lbl = [], None
for line in io.open(TB, encoding='utf-8', errors='replace'):
    s = line.strip()
    if not s:
        continue
    if s.startswith('===') or s.startswith('TYPE') or s.startswith('#'):
        if cur:
            tables.append((lbl, cur)); cur = []
        lbl = s
        continue
    nm = s.split()[0]
    cur.append(nm)
if cur:
    tables.append((lbl, cur))
print('解析到类型表 %d 张' % len(tables))

CFGS = re.compile(r'^(copy_from_user|copy_to_user|_copy_from_user|_copy_to_user|'
                  r'simple_write_to_buffer|simple_read_from_buffer|memcpy|memmove|strcpy|strscpy|'
                  r'scnprintf|snprintf)$')
name2addr = {}
for k, v in syms.items():
    name2addr.setdefault(k.split('$')[0], v)

def ins_of(nm, maxlen=160):
    a = name2addr.get(nm)
    if a is None:
        return None
    if not (BASE <= a < BASE + len(data)):
        return None
    o = a - BASE
    out = []
    for i in md.disasm(data[o:o + maxlen * 4], a):
        out.append(i)
        if i.mnemonic == 'ret' and len(out) > 6:
            break
    return out

hits = []
for lbl, members in tables:
    for nm in members:
        seq = ins_of(nm)
        if not seq:
            continue
        # 状态机: 记录 (reg -> 来源 "[base,#K]")
        src = {}
        lvl = {}
        for i in seq:
            mn, ops = i.mnemonic, i.op_str
            m = re.fullmatch(r'ldr\s+(x\d+),\s*\[(x\d+|sp)(?:,\s*#(0x[0-9a-f]+|[\d]+))?\]', mn + ' ' + ops.replace(mn, '').strip() and ops)
            if mn.startswith('ldr'):
                mm = re.fullmatch(r'(x\d+),\s*\[(x\d+|sp)\s*(?:,\s*#(0x[0-9a-f]+|\d+))?\]', ops)
                if mm:
                    dst, b, k = mm.group(1), mm.group(2), mm.group(3)
                    kk = int(k, 16) if k and 'x' in k else (int(k) if k else 0)
                    if b in src:                       # 二级解引用
                        lvl[dst] = (src[b], kk)
                    else:
                        src[dst] = kk                  # 一级: dst = *[b + kk]
                    continue
            if re.match(r'^(bl|b)$', mn):
                t = ops.strip().lstrip('#')
                tn = re.search(r'->\s*([A-Za-z0-9_.]+)', ops)
                callee = tn.group(1).split('+')[0] if tn else ''
                if CFGS.match(callee):
                    for r, pair in lvl.items():
                        hits.append((lbl, nm, callee, pair))
        if len(hits) > 4000:
            break
    if len(hits) > 4000:
        break

print('命中 %d 条(结构体字段被当内核数据指针 + 用户态搬运)' % len(hits))
seen = set()
for lbl, nm, callee, pair in hits:
    key = (nm, callee)
    if key in seen:
        continue
    seen.add(key)
    print('  %-38s <- %-24s  偏移 %s   [表 %s]' % (nm, callee, '+0x%x(%s)' % (pair[1], pair[0]), (lbl or '')[:40]))
