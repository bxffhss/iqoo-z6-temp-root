#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""专扫 `.open` 同类型表(131 成员): 找"把 filp->private_data(+0xd8)设成**堆地址/可塑形对象**"的成员。
为什么它决定成败: `.read` 槽里唯一安全的原语是 `stats_read`
  = `simple_read_from_buffer(to=用户buf, count=用户给, ppos=&file->f_pos, from=file->private_data, avail=0x63ed0)`
它的 `from` **就是 private_data 本身**(不解引用) ⇒ 只要 private_data 是**堆指针**, 我们就得到
"从堆上某处往后 400KB、偏移和长度全可控、还能重复读"的通道 ⇒ 在堆里按 `comm`/`uid=2000` 标记
认出我们自己的 task_struct/cred ⇒ 再用已证的写原语把 id 清零 = 临时 root。
用法: python scan_open_pd.py [表名关键字]
"""
import io, re, sys, collections
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

KS = r'G:\项目\Windows管理\usb\临时root\analysis\kallsyms_g2a88cd145def.txt'
IMG = r'G:\项目\Windows管理\usb\临时root\analysis\kernel_dev_g2a88cd145def.bin'
TB = r'G:\项目\Windows管理\usb\临时root\analysis\cfi_type_tables.txt'
BASE = 0xffffffc010080000
LINE = int(sys.argv[1]) if len(sys.argv) > 1 else 14239     # .open 那张表的起始行

syms = {}
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms[' '.join(p[2:])] = int(p[0], 16)
addr_of = {}
for k, v in syms.items():
    addr_of.setdefault(k.split('$')[0].split('.')[0], v)

data = io.open(IMG, 'rb').read()
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True

# ---- 取表: cfi_type_tables.txt 里 "成员 | 成员 | ..." 的行 ----
lines = io.open(TB, encoding='utf-8', errors='replace').read().splitlines()
members = []
for i in range(max(0, LINE - 3), min(len(lines), LINE + 3)):
    s = lines[i].strip()
    if '|' in s:
        members = [x.strip() for x in s.split('|') if x.strip()]
        print('用第 %d 行, 成员 %d 个' % (i + 1, len(members)))
        break
if not members:
    print('没找到成员行; 该行内容 =', lines[LINE - 1][:200])
    sys.exit(1)

KMP = re.compile(r'^(kmalloc|kmem_cache_alloc|kzalloc|__kmalloc|kmalloc_slab|kmalloc_caches|'
                 r'kmem_cache_zalloc|alloc_pages|vmalloc|__vmalloc|vzalloc|kmalloc_array|kcalloc|'
                 r'get_zeroed_page|kmemdup|memdup_user|strdup|kstrdup|of_get_property|dev_get_platdata|'
                 r'cdev_get|kernfs_get_inode|kernfs_iop|ida_alloc|idr_alloc)$')
STR_D8 = re.compile(r'str\s+(x\d+),\s*\[x(\d+),\s*#0xd8\]')
LD_D8 = re.compile(r'ldr\s+(x\d+),\s*\[x\d+,\s*#0xd8\]')

report = []
for nm in members:
    a = addr_of.get(nm)
    if a is None:
        report.append((nm, 0, '缺符号', ''))
        continue
    o = a - BASE
    if not (0 <= o < len(data) - 4):
        report.append((nm, a, '越界', ''))
        continue
    seq = list(md.disasm(data[o:o + 4 * 260], a))
    live = {}            # reg -> 说明(它装着什么)
    wrote = []
    calls = []
    for idx, i in enumerate(seq):
        mn, ops = i.mnemonic, i.op_str
        # 调用: 记录被调函数(它返回堆指针的可能性)
        if mn in ('bl', 'b') and ops.startswith('#'):
            tgt = None
            m = re.search(r'->\s*([A-Za-z0-9_.$]+)', ops)
            tn = re.search(r'#(0x[0-9a-f]+)', ops)
            if tn:
                ta = int(tn.group(1), 16)
                # 用地址反查符号
                best = None
                for k, v in syms.items():
                    if v == ta:
                        best = k.split('$')[0].split('.')[0]
                        break
                if best:
                    calls.append(best)
        m = STR_D8.fullmatch((mn + ' ' + ops).strip()) if False else STR_D8.match((mn + ' ' + ops).strip())
        if m and mn == 'str':
            src = m.group(1)
            desc = live.get(src, 'reg=%s(未知来源)' % src)
            wrote.append((i.address, src, desc))
            if src in live:
                pass
        # 记住 "x0 = 某个调用返回值"
        mm = re.fullmatch(r'mov\s+(x\d+),\s*(x\d+)', ops)
        if mm and mn == 'mov' and mm.group(2) in live:
            live[mm.group(1)] = live[mm.group(2)]
        if mn == 'bl' and calls:
            live['x0'] = 'return(%s)' % calls[-1]
        for c in (0, 1):
            pass
        # 目标寄存器被普通写覆盖 ⇒ 丢信息
        dm = re.match(r'^(?:[a-z][a-z0-9]*)\s+(x\d+)\b', ops)
        if dm and mn not in ('str', 'stp', 'stur', 'strb', 'strh'):
            if dm.group(1) != (m.group(1) if m else None):
                live.pop(dm.group(1), None)
        # 静态地址装载
        if mn == 'adrp':
            live[ops.split(',')[0].strip()] = 'adrp@%s' % ops.split('#')[-1]
    if not wrote and not calls:
        continue
    heap = [k for k in calls if KMP.match(k)]
    tag = '★堆' if heap else ('有写' if wrote else '')
    report.append((nm, a, tag, 'pd写=%d 次 %s | 调用的分配函数=%s' %
                   (len(wrote), ['%x:%s' % (w[0], w[2]) for w in wrote[:3]], heap[:4])))

print('--- 结果(只看有 private_data 写入或有分配调用的) ---')
for nm, a, tag, extra in report:
    if tag:
        print('  %-38s %016x %-6s %s' % (nm[:38], a, tag, extra))
print('--- 汇总: 成员 %d, 命中 ★堆 %d ---' % (len(members), sum(1 for r in report if r[2] == '★堆')))
