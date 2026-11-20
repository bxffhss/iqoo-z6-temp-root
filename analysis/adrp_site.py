#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""adrp_site.py —— 找"adrp+add 得到某个具体链接期地址"的代码位置(带函数归属)。
用法: PYTHONIOENCODING=utf-8 python adrp_site.py 0xffffffc0121d8b10 [...]
"""
import io, re, sys, bisect

KS = r'G:\项目\Windows管理\usb\临时root\analysis\kallsyms_g2a88cd145def.txt'
IMG = r'G:\项目\Windows管理\usb\临时root\analysis\kernel_dev_g2a88cd145def.bin'
BASE = 0xffffffc010080000
data = io.open(IMG, 'rb').read()
syms = []
for l in io.open(KS, encoding='utf-8', errors='replace'):
    p = l.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), p[1], ' '.join(p[2:])))
syms.sort()
addrs = [s[0] for s in syms]


def nm(a):
    i = bisect.bisect_right(addrs, a) - 1
    return '%s+0x%x' % (syms[i][2], a - syms[i][0]) if i >= 0 else '?'


targets = [int(x, 16) for x in sys.argv[1:]]
for T in targets:
    page = T & ~0xfff
    lo, off = T & 0xfff, 0
    hits = []
    text_end = 0x115a0000 - BASE
    while off < text_end:
        ins = int.from_bytes(data[off:off + 4], 'little')
        if (ins & 0x9f000000) == 0x90000000:
            imm = (((ins >> 29) & 3) | (((ins >> 5) & 0x7ffff) << 2))
            if imm & (1 << 20):
                imm -= 1 << 21
            pc = BASE + off
            if ((pc & ~0xfff) + (imm << 12)) & 0xffffffffffffffff == page:
                rd = ins & 31
                nxt = int.from_bytes(data[off + 4:off + 8], 'little')
                ad = (nxt == 0xFFFFFFFF)
                if (nxt & 0xFFC00000) == 0x91000000 and (nxt & 31) == rd and \
                        ((nxt >> 10) & 0xFFF) * (4 if (nxt >> 22) & 1 else 1) == lo and \
                        ((nxt >> 22) & 3) == 0:
                    hits.append(pc)
        off += 4
    print('目标 0x%x (%s) 的 adrp+add 现场: %d 处' % (T, nm(T), len(hits)))
    for h in hits:
        print('   %x  in %s' % (h, nm(h)))
