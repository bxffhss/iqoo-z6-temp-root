#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cfi_map.py —— 把 cfi_type_tables.txt 变成两张可用的表:
   (A) jt_entry[name] = 该函数的 KCFI 序言(.cfi_jt)链接地址  (= 组首地址 + 4*组内下标)
   (B) entry_addr -> (name, group_line, idx)
   并可与 kallsyms 里的 `<name>.cfi_jt` 符号交叉验证。
用法: python cfi_map.py            # 自检 + 统计
      python cfi_map.py who 0xffffffc011586f3c
"""
import io, re, sys, collections

AN = r'G:\项目\Windows管理\usb\临时root\analysis'
TB = AN + r'\cfi_type_tables.txt'
KS = AN + r'\kallsyms_g2a88cd145def.txt'

HDR = re.compile(r'^(0x[0-9a-f]{16})\s+n=(\d+)\s*(.*)$')


def load_groups():
    groups = []          # (line_no, base, [names])
    for i, l in enumerate(io.open(TB, encoding='utf-8', errors='replace')):
        m = HDR.match(l.strip())
        if not m:
            continue
        base = int(m.group(1), 16)
        rest = l.split('  ', 1)
        names = [x.strip() for x in rest[1].split('|')] if len(rest) > 1 else []
        names = [n for n in names if n]
        groups.append((i + 1, base, names, int(m.group(2))))
    return groups


def build():
    entry_of = {}        # name -> addr  (重名者取列表)
    name_of = {}         # addr -> (name, line, idx)
    for line, base, names, n in load_groups():
        for idx, nm in enumerate(names):
            a = base + 4 * idx
            entry_of.setdefault(nm, []).append((a, line, idx))
            if a in name_of and name_of[a][0] != nm:
                name_of.setdefault('_DUP', [])
            name_of[a] = (nm, line, idx)
    return entry_of, name_of


def load_kallsyms_cfi():
    d = {}
    for l in io.open(KS, encoding='utf-8', errors='replace'):
        p = l.split()
        if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]) and p[2].endswith('.cfi_jt'):
            d[int(p[0], 16)] = p[2][:-len('.cfi_jt')]
    return d


if __name__ == '__main__':
    entry_of, name_of = build()
    ks = load_kallsyms_cfi()
    print('组数=%d  成员条目=%d  唯一名字=%d  kallsyms .cfi_jt 符号=%d' %
          (len(load_groups()), len(name_of), len(entry_of), len(ks)))
    ok = bad = 0
    for a, nm in ks.items():
        got = name_of.get(a)
        if got and got[0] == nm:
            ok += 1
        else:
            bad += 1
            if bad < 12:
                print('  不一致: kallsyms %016x=%s ; 计算=%s' % (a, nm, got))
    print('交叉验证: 一致 %d, 不一致 %d' % (ok, bad))
    if len(sys.argv) > 2:
        a = int(sys.argv[2], 16)
        print('0x%x -> %s ; kallsyms=%s' % (a, name_of.get(a), ks.get(a)))
    for nm in ('seq_read', 'seq_open', 'single_open', 'seq_lseek', 'seq_release',
               'single_release', 'stat_open', 'cpuinfo_open', 'kmsg_open'):
        print('%-16s %s' % (nm, entry_of.get(nm)))
