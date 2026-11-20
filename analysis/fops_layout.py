#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fops_layout.py —— 用"槽位里的函数名"把本构建的 struct file_operations 布局钉死.
用法: PYTHONIOENCODING=utf-8 python fops_layout.py [sym1,sym2,...]
"""
import io, re, sys, struct, bisect, collections

AN = r'G:\项目\Windows管理\usb\临时root\analysis'
KS = AN + r'\kallsyms_g2a88cd145def.txt'
IMG = AN + r'\kernel_dev_g2a88cd145def.bin'
TB = AN + r'\cfi_type_tables.txt'
BASE = 0xffffffc010080000
HDR = re.compile(r'^(0x[0-9a-f]{16})\s+n=(\d+)\s*(.*)$')

name_of_e = {}
for i, l in enumerate(io.open(TB, encoding='utf-8', errors='replace')):
    m = HDR.match(l.strip())
    if not m:
        continue
    rest = l.split('  ', 1)
    names = [x.strip() for x in rest[1].split('|')] if len(rest) > 1 else []
    for idx, nm in enumerate([n for n in names if n]):
        name_of_e[int(m.group(1), 16) + 4 * idx] = nm

syms = {}
typ = {}
for l in io.open(KS, encoding='utf-8', errors='replace'):
    p = l.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms[' '.join(p[2:])] = int(p[0], 16)
        typ[int(p[0], 16)] = p[1]
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

WANT = sys.argv[1] or 'proc_stat_operations,proc_kmsg_operations,ext4_file_operations,\
sock_stream_inodeops,binder_fops,binder_fops_legacy,dgsock_fops,def_chr_fops,block_fops,\
turbo_stats_fops,kmsg_fops,udm_fops,seq_fops,video_ops,kgsl_fops,ion_fops'
for nm in WANT.replace('\\\n', '').replace('\n', '').split(','):
    nm = nm.strip()
    a = syms.get(nm)
    if a is None:
        print('%-28s 缺符号' % nm)
        continue
    print('%-28s @0x%x  type=%s' % (nm, a, typ.get(a)))
    for off in range(0, 0xC0, 8):
        v = RELA.get(a + off)
        f = name_of_e.get(v) if v else None
        if v:
            print('   +0x%-4x %016x  %s' % (off, v, f or '?'))
