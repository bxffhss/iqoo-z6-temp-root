# -*- coding: utf-8 -*-
"""ko_crc_deep.py — 回答一个具体问题: 离线抽出的 __kcrctab 与厂商 .ko 的 __versions
为什么只有**一半**吻合? 三种解释各自的可证伪判据:
  H1 我的 name<->crc 配对错位      ⇒ 期望值应能在表里**别的下标**找到
  H2 真值存在别处(ASM_MODVERSIONS 把 CRC 放 .rodata 的 __crc_*, __kcrctab 存相对偏移)
                                    ⇒ 期望值应能在**整个镜像**里找到(且偏移能自洽)
  H3 /vendor 的 .ko 与运行内核不是同一构建(OTA 只更了其中一边)
                                    ⇒ "已加载"的那批应当**全吻合**(不然内核早就拒了),
                                       未加载的那批可以不吻合
用法: python analysis/ko_crc_deep.py <一个或多个 .ko>
"""
import io, os, struct, sys, collections

AN = r'G:\项目\Windows管理\usb\临时root\analysis'
BASE = 0xffffffc010080000
IMG = os.path.join(AN, 'kernel_dev_g2a88cd145def.bin')
SYM = os.path.join(AN, 'Module.symvers_dev')
for _n in ('stdout', 'stderr'):
    try:
        getattr(sys, _n).reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

img = io.open(IMG, 'rb').read()
# 整镜像里每个 u32 的出现位置(只建一次, 供"值在哪"查询)
ref = {}
for l in io.open(SYM, encoding='utf-8', errors='replace'):
    p = l.rstrip('\n').split('\t')
    if len(p) >= 2:
        ref[p[1]] = int(p[0], 16)

ks = {}
for l in io.open(os.path.join(AN, 'kallsyms_g2a88cd145def.txt'), encoding='utf-8', errors='replace'):
    p = l.split()
    if len(p) >= 3 and len(p[0]) == 16:
        ks.setdefault(p[2], int(p[0], 16))
T0, T1 = ks['__start___kcrctab'], ks['__stop___kcrctab']
G0, G1 = ks['__start___kcrctab_gpl'], ks['__stop___kcrctab_gpl']
tab = struct.unpack('<%dI' % ((T1 - T0) // 4), img[T0 - BASE:T1 - BASE])
tabg = struct.unpack('<%dI' % ((G1 - G0) // 4), img[G0 - BASE:G1 - BASE])
where = collections.defaultdict(list)
for i, v in enumerate(tab):
    where[v].append(('ksymtab', i))
for i, v in enumerate(tabg):
    where[v].append(('ksymtab_gpl', i))


def sections(path):
    d = io.open(path, 'rb').read()
    e_shoff = struct.unpack_from('<Q', d, 0x28)[0]
    es, en, estr = struct.unpack_from('<HHH', d, 0x3a)

    def sh(i):
        o = e_shoff + i * es
        nm, ty = struct.unpack_from('<II', d, o)
        off, sz = struct.unpack_from('<QQ', d, o + 0x18)
        return nm, ty, off, sz
    # e_shstrndx 是**段表下标**, 不是偏移(第一版在这里踩过坑, 导致段名全是垃圾)
    strtab = sh(estr)[2]
    names = {}
    for i in range(en):
        nm, ty, off, sz = sh(i)
        e = d.index(b'\0', strtab + nm)
        names[d[strtab + nm:e].decode('ascii', 'replace')] = (off, sz)
    return names, d


def modinfo(d, names):
    out = {}
    if '.modinfo' not in names:
        return out
    o, sz = names['.modinfo']
    for s in d[o:o + sz].split(b'\0'):
        if b'=' in s:
            k, v = s.split(b'=', 1)
            out[k.decode()] = v.decode('ascii', 'replace')
    return out


def versions(d, names):
    if '__versions' not in names:
        return []
    o, sz = names['__versions']
    rows = []
    for i in range(sz // 64):
        b = o + i * 64
        crc = struct.unpack_from('<Q', d, b)[0]
        raw = d[b + 8:b + 64]
        z = raw.find(b'\0')
        rows.append((raw[:z].decode('ascii', 'replace'), crc & 0xffffffff))
    return rows


for path in sys.argv[1:]:
    names, d = sections(path)
    mi = modinfo(d, names)
    rows = versions(d, names)
    ok = sum(1 for nm, c in rows if nm in ref and ref[nm] == c)
    print('== %-34s name=%-20s depends=%-28s vermagic=%s' % (
        os.path.basename(path), mi.get('name', '?'), mi.get('depends', '-') or '(无)',
        mi.get('vermagic', '?')[:46]))
    print('   __versions %d 条: 与离线表吻合 %d, 不吻合 %d' % (len(rows), ok, len(rows) - ok))
    hs = collections.Counter()
    for nm, c in rows:
        if nm in ref and ref[nm] == c:
            hs['match'] += 1
            continue
        w = where.get(c, [])
        hs['值在表里但下标不对' if w else '整个 CRC 表里根本没有这个值'] += 1
        if not ok:
            pass
    print('   失败原因的分布: ' + ', '.join('%s=%d' % kv for kv in sorted(hs.items())))
    bad = [(nm, c) for nm, c in rows if nm not in ref or ref[nm] != c][:5]
    for nm, c in bad:
        print('     %-32s ko=%08x img=%s  该值在表中的位置=%s' % (
            nm, c, ('%08x' % ref[nm]) if nm in ref else '(名字不在表里)', where.get(c, [])[:3]))
print('\n对照: 表大小 非gpl=%d gpl=%d (共 %d)' % (len(tab), len(tabg), len(tab) + len(tabg)))
