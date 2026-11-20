#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ctls2.py —— 用镜像里保留的 **.rela** 表反查 ctl_table 条目(裸 Image 的 .data 里指针全是 0,
只有 rela 记录才有"目的地址 ← 链接期值"这一手信息)。

实测坐实的 5.4.281 布局(条目大小 0x40):
    procname +0x00 / data +0x08 / maxlen +0x10(int) / mode +0x14(u16)
    child +0x18 / proc_handler +0x20 / extra1 +0x28 / extra2 +0x30
判据: 从设备 `cat` 成功过的 net 路径名 → 镜像里的字符串地址 → rela 里 addend=该地址的记录
      → 目的地址就是条目的 procname 字段(=条目基址), 于是 `.data` 字段 = 基址+8 是**确定的**。
用法: python ctls2.py netread.txt
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
    if a is None:
        return None
    i = bisect.bisect_right(addrs, a) - 1
    if i < 0:
        return None
    sa, sn = syms[i]
    nxt = addrs[i + 1] if i + 1 < len(addrs) else sa + 0x1000
    return '%s+0x%x%s' % (sn, a - sa, '' if a < nxt else '(越界)')


def load_rela():
    """扫全镜像找 R_AARCH64_RELATIVE(1027) 记录: {dest,1027,addend} 24 字节一条。"""
    out = {}
    for off in range(0, len(data) - 0x18, 8):
        info = struct.unpack_from('<Q', data, off + 8)[0]
        if info == 0x403:
            dest = struct.unpack_from('<Q', data, off)[0]
            add = struct.unpack_from('<Q', data, off + 0x10)[0]
            if BASE <= dest < BASE + 0x4000000:
                out[dest] = add
    return out


RELA = load_rela()
BY_ADDEND = {}
for d, a in RELA.items():
    BY_ADDEND.setdefault(a, []).append(d)
print('# rela 记录 %d 条 / 独立值 %d' % (len(RELA), len(BY_ADDEND)), flush=True)


def ptr(a):
    """取一个链接期地址处的"运行时值": .data 里没重定位的字段读 rela, 已重定位的读 qword。"""
    v = RELA.get(a)
    if v:
        return v
    try:
        return struct.unpack_from('<Q', data, a - BASE)[0]
    except Exception:
        return None


def find_string(name):
    pat = b'\x00' + name.encode() + b'\x00'
    out, i = [], 0
    while True:
        j = data.find(pat, i)
        if j < 0:
            return out
        out.append(BASE + j + 1)
        i = j + 1


def entries_for(name):
    res = []
    for sa in find_string(name):
        for dest in BY_ADDEND.get(sa, ()):
            if (dest & 7):
                continue
            ml = struct.unpack_from('<I', data, dest - BASE + 0x10)[0]
            md = struct.unpack_from('<H', data, dest - BASE + 0x14)[0]
            if ml and ml <= 0x200 and md and md <= 0o7777:
                res.append(dict(name=name, entry=dest, data_f=dest + 0x08,
                                data_v=ptr(dest + 0x08), maxlen=ml, mode=oct(md),
                                handler=ptr(dest + 0x20)))
    return res


def main():
    lst = sys.argv[1]
    seen, names = set(), []
    for line in io.open(lst, encoding='utf-8', errors='replace'):
        p = line.strip().split('|')
        if not p or not p[0]:
            continue
        b = os.path.basename(p[0])
        if b not in seen:
            seen.add(b)
            names.append(b)
    rows = []
    for n in names:
        rows += entries_for(n)
    rows.sort(key=lambda r: (-r['maxlen'], r['name']))
    print('%-26s %-18s %-18s %6s %6s %-36s %s' %
          ('NAME', 'ENTRY', '.data_FIELD', 'MAXLEN', 'MODE', 'HANDLER(cfi_jt)', 'orig_data'))
    for r in rows:
        print('%-26s %016x %016x %6d %6s %-36s %s' %
              (r['name'][:26], r['entry'], r['data_f'], r['maxlen'], r['mode'],
               (name_of(r['handler']) or '?')[:36],
               '0x%x' % r['data_v'] if r['data_v'] else '?'))



main()
