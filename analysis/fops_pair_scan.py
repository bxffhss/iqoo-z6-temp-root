#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fops_pair_scan.py —— 列出"read 类型函数 × open 函数"的配对, 并挑出 open 是
   simple_open/debugfs_open/tracing_open_*(= private_data 取 inode->i_private) 的组合。
用法: PYTHONIOENCODING=utf-8 python fops_pair_scan.py
"""
import io, re, sys, struct, bisect, collections

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


def sym_at(a):
    i = bisect.bisect_right(addrs, a) - 1
    return syms[i] if i >= 0 else None


def obj_span(a):
    i = bisect.bisect_right(addrs, a)
    return 0 if i == 0 or i >= len(syms) else syms[i][0] - syms[i - 1][0]


name_of_e, groups = {}, {}
for i, l in enumerate(io.open(TB, encoding='utf-8', errors='replace')):
    m = HDR.match(l.strip())
    if not m:
        continue
    rest = l.split('  ', 1)
    names = [strip(x.strip()) for x in rest[1].split('|')] if len(rest) > 1 else []
    groups[i + 1] = (int(m.group(1), 16), [n for n in names if n])
    for idx, nm in enumerate([n for n in names if n]):
        name_of_e[int(m.group(1), 16) + 4 * idx] = nm
READ_G = set(groups[14233][1])
OPEN_G = set(groups[14253][1]) | set(groups[14240][1])

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

IPRIV = ('simple_open', 'debugfs_open', 'tracing_open_generic', 'tracing_open_generic_tr',
         'tracing_open_file_tr', 'relay_file_open', 'f_cdev_open', 'ffs_ep0_open')
rows = []
for obj, slots in byobj.items():
    rd, op = slots.get(0x10), slots.get(0x70)
    if not rd and not op:
        continue
    rows.append((obj, objinfo[obj], rd, op, slots.get(0x20), slots.get(0x8), slots.get(0x80)))
print('带 read 或 open 槽的静态对象总数 = %d' % len(rows))
print()
print('=== 1) open 是 "private_data = inode->i_private" 一族的对象 ===')
for obj, (a, t, n), rd, op, it, lk, rel in sorted(rows, key=lambda x: x[0]):
    if op in IPRIV:
        print('  %-42s @0x%016x [%s] sz~0x%-6x open=%-22s read=%-26s iter=%s llseek=%s' %
              (n[:42], a, t, obj_span(a), op, rd, it, lk))
print()
print('=== 2) read 属于 .read 类型组(14233) 且 open 也在 open 组 的对象数 ===')
c = collections.Counter()
for obj, (a, t, n), rd, op, it, lk, rel in rows:
    if rd in READ_G:
        c[op or '(open 槽为空)'] += 1
for k, v in c.most_common(200):
    print('   open=%-34s %d' % (k, v))
print()
print('=== 3) 特别关注: seq_read + 非 heap 的 open ===')
for obj, (a, t, n), rd, op, it, lk, rel in sorted(rows, key=lambda x: x[0]):
    if rd == 'seq_read':
        flag = '★' if op in IPRIV else ' '
        print('  %s %-42s [%s] open=%-28s llseek=%-20s release=%s' %
              (flag, n[:42], t, op, lk, rel))
