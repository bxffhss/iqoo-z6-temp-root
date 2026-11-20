# -*- coding: utf-8 -*-
"""kcrctab_dump.py — 从**与设备逐字同构建**的裸 Image 离线抽出导出符号 + MODVERSIONS CRC,
生成 analysis/Module.symvers_dev(造外部 .ko 的前提)。全程不碰设备。

三条一手依据(不是抄上游头文件):
1. 条目步长 = 24 字节, 由两个独立计数互相卡死:
     .ksymtab   ffffffc0122eb018..ffffffc012316bd8 = 0x2BBC0 = 179136 = 7464 * 24
     .kcrctab   ffffffc01233a608..ffffffc012341aa8 = 0x74A0  =  29856 = 7464 * 4
     .ksymtab_gpl = 0x23A30 = 145968 = 6082 * 24 ; .kcrctab_gpl = 24328 = 6082 * 4  ✔
2. 裸 Image 是 **rela 化**的: 指针字段(value/name/namespace)在文件里全是 0,
   真值只存在于 R_AARCH64_RELATIVE(=1027) 表项里(dest=字段地址, addend=链接期目标)
   —— 与 [[image-rela-layout]] 记录的 dump_obj.py 手法一致。
3. CRC 本身是普通 u32 数据(不指针), 所以直接躺在 .kcrctab 里可读(已肉眼见到 6b5564fa 这类值)。
文件偏移口径(项目一手): file = VA - 0xffffffc010080000 (= _text)。
自校验: name 必须解析成 ASCII; 函数类符号的 value 应与 kallsyms 同名地址一致。
"""
import io, os, struct, sys, bisect, collections

BASE = r'G:\项目/Windows管理\usb\临时root'
AN = os.path.join(BASE, 'analysis')
KL = os.path.join(AN, 'kallsyms_g2a88cd145def.txt')
IMG = os.path.join(AN, 'kernel_dev_g2a88cd145def.bin')
TEXT_VA = 0xffffffc010080000
STRIDE = 24
OUT = os.path.join(AN, 'Module.symvers_dev')
# 控制台是 gbk, 统一按 UTF-8 输出, 免得被中文/箭头噎死
for _n in ('stdout', 'stderr'):
    try:
        getattr(sys, _n).reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

GROUPS = [
    ('__start___ksymtab', '__stop___ksymtab', '__start___kcrctab', '__stop___kcrctab', 'EXPORT_SYMBOL'),
    ('__start___ksymtab_gpl', '__stop___ksymtab_gpl', '__start___kcrctab_gpl', '__stop___kcrctab_gpl', 'EXPORT_SYMBOL_GPL'),
    ('__start___ksymtab_gpl_future', '__stop___ksymtab_gpl_future',
     '__start___kcrctab_gpl_future', '__stop___kcrctab_gpl_future', 'EXPORT_SYMBOL_FUTURE'),
    ('__start___ksymtab_unused', '__stop___ksymtab_unused',
     '__start___kcrctab_unused', '__stop___kcrctab_unused', 'EXPORT_SYMBOL_UNUSED'),
    ('__start___ksymtab_unused_gpl', '__stop___ksymtab_unused_gpl',
     '__start___kcrctab_unused_gpl', '__stop___kcrctab_unused_gpl', 'EXPORT_SYMBOL_UNUSED_GPL'),
]

data = io.open(IMG, 'rb').read()
syms = []
for l in io.open(KL, encoding='utf-8', errors='replace'):
    p = l.split()
    if len(p) >= 3 and len(p[0]) == 16:
        try:
            syms.append((int(p[0], 16), p[1], ' '.join(p[2:])))
        except ValueError:
            pass
syms.sort()
addrs = [a for a, _, _ in syms]
byname = {}
for a, t, n in syms:
    byname.setdefault(n, (a, t))


def sec_va(nm):
    v = byname.get(nm)
    return v[0] if v else None


def rela_table():
    """扫全镜像的 R_AARCH64_RELATIVE(1027) 项: dest(字段地址) -> addend(链接期目标)。"""
    R = {}
    for off in range(0, len(data) - 0x18, 8):
        if struct.unpack_from('<Q', data, off + 8)[0] == 1027:
            R[struct.unpack_from('<Q', data, off)[0]] = struct.unpack_from('<Q', data, off + 16)[0]
    return R


def cstr(va, limit=96):
    if va is None:
        return None
    o = va - TEXT_VA
    if o < 0 or o >= len(data):
        return None
    b = data[o:min(o + limit, len(data))]
    i = b.find(b'\0')
    if i < 0:
        return None
    s = b[:i]
    if not s or any(c < 0x20 or c > 0x7e for c in s):
        return None
    return s.decode('ascii')


def name_of(a):
    i = bisect.bisect_right(addrs, a) - 1
    if i < 0:
        return '?'
    return '%s(%s)+0x%x' % (syms[i][2], syms[i][1], a - syms[i][0])


def main():
    print('image = %d 字节, kallsyms = %d 行' % (len(data), len(syms)))
    R = rela_table()
    print('R_AARCH64_RELATIVE 项 = %d' % len(R))
    rows, stat = [], collections.Counter()
    for (s0n, s1n, c0n, c1n, etype) in GROUPS:
        s0, s1, c0, c1 = (sec_va(x) for x in (s0n, s1n, c0n, c1n))
        if None in (s0, s1, c0, c1):
            continue
        nb, nc = s1 - s0, c1 - c0
        if nb % STRIDE:
            print('!! %s 尺寸 %x 不被 %d 整除 ⇒ 步长假设错' % (s0n, nb, STRIDE))
            return 2
        cnt = nb // STRIDE
        if cnt * 4 != nc:
            print('!! %s: %d 项 vs CRC %d 字节 ⇒ 不自洽' % (s0n, cnt, nc))
            return 2
        if cnt == 0:
            continue
        print('-- %s: %d 个导出 (%s)' % (s0n, cnt, etype))
        crcs = struct.unpack('<%dI' % cnt, data[c0 - TEXT_VA:c0 - TEXT_VA + cnt * 4])
        for i in range(cnt):
            a = s0 + i * STRIDE
            fv, fn, fs = R.get(a), R.get(a + 8), R.get(a + 16)
            nm = cstr(fn)
            if nm is None:
                stat['name_unparsable'] += 1
                continue
            stat['ok'] += 1
            ns = cstr(fs) if fs else ''
            hit = byname.get(nm)
            if hit is None:
                for cand in (nm + '.', nm + '$'):
                    kk = [k for k in byname if k.startswith(cand)]
                    if kk:
                        hit = byname[kk[0]]
                        break
            if hit and hit[1] in 'TtWw':
                stat['func_addr_ok' if hit[0] == fv else 'func_addr_MISMATCH'] += 1
            else:
                stat['data_or_unmatched'] += 1
            rows.append((crcs[i], nm, etype, ns or '', fv or 0, hit[1] if hit else '?'))
    print('自校验: ' + ', '.join('%s=%d' % kv for kv in sorted(stat.items())))
    nns = sum(1 for r in rows if r[3])
    print('带 namespace 的导出符号 = %d (造模块时要 MODULE_IMPORT_NS)' % nns)
    with io.open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        for crc, nm, etype, ns, value, t in sorted(rows, key=lambda x: x[1]):
            f.write('0x%08x\t%s\t(kernel)\t%s\t%s\n' % (crc, nm, etype, ns))
    print('WROTE %s  (%d 行)' % (OUT, len(rows)))
    for probe in ('printk', 'kmalloc_trace', 'kmem_cache_alloc', 'kmem_cache_free',
                  'copy_process', 'commit_creds', 'prepare_kernel_cred', 'register_sysctl',
                  'single_open', 'seq_printf', 'alloc_page', 'vmalloc'):
        got = [r for r in rows if r[1] == probe]
        if got:
            print('  %-22s crc=%08x %-20s value=%x' % (probe, got[0][0], got[0][2], got[0][4]))
    return 0


sys.exit(main())
