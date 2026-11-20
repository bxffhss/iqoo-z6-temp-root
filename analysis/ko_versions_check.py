# -*- coding: utf-8 -*-
"""ko_versions_check.py — 用**厂商自己的 .ko** 校验离线抽出来的 CRC 表对不对。
这是"能不能造出过 MODVERSIONS 检查的外部模块"的唯一硬判据(不需要设备, 只要一个 .ko 文件)。

做法: 解析 ELF 的 `__versions` 段(5.4 = struct modversion_info{char name[45]; u32 crc;} 的数组,
但为了不被记忆坑到, 这里**不猜步长**: 对 48/52/56 三种候选分别解析, 取"与离线表逐符号吻合"最多的那个。
比对基准 = analysis/Module.symvers_dev(由 kcrctab_dump.py 从裸 Image 的 .ksymtab+.kcrctab 抽出)。

用法: python analysis/ko_versions_check.py <厂商.ko 路径> [第二个 .ko ...]
"""
import io, os, struct, sys, collections

AN = r'G:\项目\Windows管理\usb\临时root\analysis'
SYM = os.path.join(AN, 'Module.symvers_dev')
for _n in ('stdout', 'stderr'):
    try:
        getattr(sys, _n).reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass


def load_symvers():
    m = {}
    if not os.path.exists(SYM):
        raise SystemExit('先跑 analysis/kcrctab_dump.py 生成 Module.symvers_dev')
    for l in io.open(SYM, encoding='utf-8', errors='replace'):
        p = l.rstrip('\n').split('\t')
        if len(p) >= 2:
            m[p[1]] = int(p[0], 16)
    return m


def sections(path):
    """返回 {段名: (offset, size)}(只做 64 位小端 ELF, aarch64 够用)。"""
    d = io.open(path, 'rb').read()
    if d[:4] != b'\x7fELF' or d[4] != 2 or d[5] != 1:
        raise SystemExit('%s 不是 64 位小端 ELF' % path)
    e_shoff = struct.unpack_from('<Q', d, 0x28)[0]
    e_shentsize = struct.unpack_from('<H', d, 0x3a)[0]
    e_shnum = struct.unpack_from('<H', d, 0x3c)[0]
    e_shstrndx = struct.unpack_from('<H', d, 0x3e)[0]

    def sh(i):
        o = e_shoff + i * e_shentsize
        name, stype = struct.unpack_from('<II', d, o)
        offset, size = struct.unpack_from('<QQ', d, o + 0x18)
        return name, stype, offset, size

    strtab = sh(e_shstrndx)[2]

    def sname(off):
        e = d.index(b'\0', strtab + off)
        return d[strtab + off:e].decode('ascii', 'replace')

    out = {}
    for i in range(e_shnum):
        nm, stype, off, size = sh(i)
        out[sname(nm)] = (off, size, stype)
    return out, d


def try_stride(data, off, size, stride, name_at, namelen, crc_at):
    rows = []
    n = size // stride
    for i in range(n):
        base = off + i * stride
        raw = data[base + name_at:base + name_at + namelen]
        z = raw.find(b'\0')
        nm = raw[:z if z >= 0 else namelen]
        if not nm or any(c < 0x20 or c > 0x7e for c in nm):
            return None
        crc = struct.unpack_from('<I', data, base + crc_at)[0]
        rows.append((nm.decode('ascii', 'replace'), crc))
    return rows


def main():
    ref = load_symvers()
    print('离线表符号数 = %d' % len(ref))
    for path in sys.argv[1:]:
        print('\n===== %s =====' % path)
        secs, data = sections(path)
        for want in ('.modinfo', '__versions', '__ksymtab', '__kcrctab', '___versions'):
            if want in secs:
                o, sz, t = secs[want]
                print('  段 %-12s off=0x%x size=0x%x' % (want, o, sz))
        if '__versions' not in secs:
            print('  ⇒ 该 .ko 没有 __versions 段(说明它不需要 CRC 或未开 MODVERSIONS 依赖)')
            continue
        o, sz, _ = secs['__versions']
        print('  __versions 尺寸 0x%x = %d 字节' % (sz, sz))
        print('  头 96 字节 = %s' % data[o:o + 96].hex())
        best = None
        # 一手观测到的布局: {u64 crc; char name[56];} = 64 字节/条 ⇒ name_at=8, crc_at=0
        for stride, name_at, namelen, crc_at in ((64, 8, 56, 0), (64, 0, 56, 56), (48, 0, 45, 45),
                                                 (52, 0, 48, 48), (56, 0, 48, 48), (72, 0, 64, 64)):
            rows = try_stride(data, o, sz, stride, name_at, namelen, crc_at)
            if rows is None:
                continue
            good = sum(1 for nm, crc in rows if nm in ref and ref[nm] == crc)
            known = sum(1 for nm, crc in rows if nm in ref)
            print('  stride=%d name_at=%d crc_at=%d ⇒ %d 条, 名字在离线表里 %d, **CRC 逐条吻合 %d**'
                  % (stride, name_at, crc_at, len(rows), known, good))
            if best is None or good > best[0]:
                best = (good, len(rows), stride, rows)
        if best:
            good, total, stride, rows = best
            print('  判定(stride=%d): %d/%d 吻合 ⇒ %s' % (
                stride, good, total,
                '离线 CRC 表**可用**(finit_module 的 CRC 校验能过)' if total and good == total else
                ('离线 CRC 表**部分**吻合' if good else '离线 CRC 表**对不上**')))
            for nm, crc in rows[:6]:
                print('    %-24s ko_crc=%08x img_crc=%s' % (nm, crc, ('%08x' % ref[nm]) if nm in ref else '-'))
    return 0


sys.exit(main())
