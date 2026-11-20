#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gvar_read_scan.py —— 找"把用户态数据从**静态全局指针变量**指向的内存拷出去"的读函数。
这类是本项目写原语唯一能劫持的读原语: 变量本身在 .data/.bss(地址已知、可写), 我们用
形状(2) 把一个"可写核地址"写进它 => 下一次 read() 就把那个地址往后的内存吐给我们。

扫描范围: 所有 fops 的 .read(+0x10)/.read_iter(+0x20) 函数(由 KCFI 序言 + .rela 定位),
外加任何 bl _copy_to_user/simple_read_from_buffer/memory_read_from_buffer 的位置。
判定: 在 bl 时刻, 源寄存器(x1 或 x3)的来源是 ('gvar', 静态地址) 或 ('pd'->gvar)。
用法: PYTHONIOENCODING=utf-8 python gvar_read_scan.py
"""
import io, re, sys, struct, bisect, collections
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

AN = r'G:\项目\Windows管理\usb\临时root\analysis'
KS = AN + r'\kallsyms_g2a88cd145def.txt'
IMG = AN + r'\kernel_dev_g2a88cd145def.bin'
TB = AN + r'\cfi_type_tables.txt'
BASE = 0xffffffc010080000
HDR = re.compile(r'^(0x[0-9a-f]{16})\s+n=(\d+)\s*(.*)$')
strip = lambda n: n.split('$')[0].split('.')[0]

syms = []
for l in io.open(KS, encoding='utf-8', errors='replace'):
    p = l.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), p[1], ' '.join(p[2:])))
syms.sort()
addrs = [s[0] for s in syms]
fnaddr = {}
for a, t, n in syms:
    if t in 'tT':
        fnaddr.setdefault(strip(n), a)


def sym_at(a):
    i = bisect.bisect_right(addrs, a) - 1
    return syms[i] if i >= 0 else None


def obj_span(a):
    i = bisect.bisect_right(addrs, a)
    return 0 if i == 0 or i >= len(syms) else syms[i][0] - syms[i - 1][0]


name_of_e = {}
for i, l in enumerate(io.open(TB, encoding='utf-8', errors='replace')):
    m = HDR.match(l.strip())
    if m:
        rest = l.split('  ', 1)
        names = [strip(x.strip()) for x in rest[1].split('|')] if len(rest) > 1 else []
        for idx, nm in enumerate([n for n in names if n]):
            name_of_e[int(m.group(1), 16) + 4 * idx] = nm
data = io.open(IMG, 'rb').read()
RELA = {}
pat = struct.pack('<Q', 1027)
pos = 0
while True:
    k = data.find(pat, pos)
    if k < 0:
        break
    if k % 8 == 0:
        RELA[struct.unpack_from('<Q', data, k - 8)[0]] = struct.unpack_from('<Q', data, k + 8)[0]
    pos = k + 1
byobj = collections.defaultdict(dict)
objinfo = {}
for a, v in RELA.items():
    nm = name_of_e.get(v)
    s = sym_at(a) if nm else None
    if s:
        byobj[s[0]][a - s[0]] = nm
        objinfo[s[0]] = s

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True
SRF = fnaddr.get('simple_read_from_buffer')
MRF = fnaddr.get('memory_read_from_buffer')
CTU = fnaddr.get('_copy_to_user')
CALLERS = {SRF: 'simple_read_from_buffer(x3)', MRF: 'memory_read_from_buffer(x3)',
           CTU: '_copy_to_user(x1)'}
SLOTS = {'simple_read_from_buffer': ('x3', 'x4'), 'memory_read_from_buffer': ('x3', 'x4'),
         '_copy_to_user': ('x1', 'x2')}


def analyze(fa, limit):
    o = fa - BASE
    n = max(1, min(600, limit // 4))
    try:
        seq = list(md.disasm(data[o:o + 4 * n], fa))
    except Exception:
        return []
    live, out = {}, []
    for i in seq:
        full = (i.mnemonic + ' ' + i.op_str).strip()
        if i.mnemonic == 'bl' and full.split()[-1].startswith('#'):
            tv = int(full.split('#')[-1], 16)
            lbl = CALLERS.get(tv)
            if lbl:
                src, cnt = SLOTS[lbl.split('(')[0]]
                out.append((i.address, lbl, live.get(src), live.get(cnt)))
            live = {}
            continue
        if i.mnemonic == 'adrp':
            try:
                live[i.op_str.split(',')[0].strip()] = ('adrp', int(i.op_str.split('#')[-1], 16))
            except ValueError:
                pass
            continue
        mm = re.match(r'^(?:ldr|ldrb|ldrbu)\s+(x\d+|w\d+),\s*\[x(\d+),\s*#(0x[0-9a-f]+)\]$', full)
        if mm:
            dst = 'x' + mm.group(1)[1:]
            if live.get(mm.group(2), ('', 0))[0] == 'adrp':
                live[dst] = ('gvar', live[mm.group(2)][1] + int(mm.group(3), 16))
            elif live.get(mm.group(2), ('', 0))[0].startswith(('pd', 'gvar')):
                live[dst] = ('ind:' + live[mm.group(2)][0], live[mm.group(2)][1])
            else:
                live[dst] = ('ldr', 'x%s+%s' % (mm.group(2), mm.group(3)))
            continue
        mm = re.match(r'^(?:ldr)\s+(x\d+),\s*\[x(\d+)\]$', full)
        if mm:
            dst = mm.group(1)
            if live.get(mm.group(2), ('', 0))[0] == 'adrp':
                live[dst] = ('gvar', live[mm.group(2)][1])
            else:
                live[dst] = ('ldr', 'x%s' % mm.group(2))
            continue
        mm = re.match(r'^(?:ldp|ldnp)\s+(x\d+),\s*(x\d+),\s*\[x(\d+),\s*#?(0x[0-9a-f]+|0)?\]$', full)
        if mm:
            for d in (mm.group(1), mm.group(2)):
                live[d] = ('ldr?', None)
            continue
        mm = re.match(r'^mov\s+(x\d+),\s*(x\d+)$', full)
        if mm:
            live[mm.group(1)] = live.get(mm.group(2), ('unk', None))
            continue
        mm = re.match(r'^add\s+(x\d+),\s*(x\d+),\s*#(0x[0-9a-f]+|\d+)$', full)
        if mm:
            v = live.get(mm.group(2), ('unk', None))
            live[mm.group(1)] = (v[0], (v[1] + int(mm.group(3), 16)) if isinstance(v[1], int) else v[1])
            continue
        mm = re.match(r'^mov\s+(x\d+),\s*#(0x[0-9a-f]+|\d+)$', full)
        if mm:
            live[mm.group(1)] = ('imm', int(mm.group(2), 16))
            continue
        mm = re.match(r'^mov\s+(w\d+),\s*#(0x[0-9a-f]+|\d+)$', full)
        if mm:
            live['x' + mm.group(1)[1:]] = ('imm', int(mm.group(2), 16))
            continue
        mm = re.match(r'^[a-z][a-z0-9]*\s+(x\d+)[,\]]', full)
        if mm and i.mnemonic not in ('str', 'stp', 'stur'):
            live.pop(mm.group(1), None)
    return out


print('=== 读函数里"源 = 静态全局变量内容(gvar)"的调用点 ===')
seen = set()
rows = []
for obj, slots in sorted(byobj.items()):
    for off in (0x10, 0x20):
        f = slots.get(off)
        if not f or (f, obj) in seen or f not in fnaddr:
            continue
        seen.add((f, obj))
        fa = fnaddr[f]
        for pc, lbl, src, cnt in analyze(fa, obj_span(fa) or 0x300):
            kind = src[0] if src else None
            if kind and (kind == 'gvar' or kind.startswith('ind:')):
                a, t, n = objinfo[obj]
                gv = src[1]
                s2 = sym_at(gv) if gv else None
                rows.append((f, n, t, a, off, lbl, kind, gv, s2, cnt, slots.get(0x70), slots.get(0x8)))
for f, n, t, a, off, lbl, kind, gv, s2, cnt, op, lk in rows:
    print('  %-28s fops=%s[%s]@0x%x(+0x%x) %s <- %s [%s]%s' %
          (f[:28], n[:24], t, a, off, lbl,
           ('%s(%s)+0x%x' % (s2[2], s2[1], gv - s2[0])) if s2 else hex(gv),
           kind, ' avail=%s' % (cnt,) if cnt else ''))
    print('       open=%s llseek=%s' % (op, lk))
print('  命中 %d' % len(rows))
