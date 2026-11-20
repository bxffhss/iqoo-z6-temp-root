#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pd_static_scan.py —— 全镜像找 "把**静态对象地址**写进 filp->private_data(+0xd8)" 的代码.

  1) 按指令编码线性筛 `str x?,[x?,#0xd8]` 与 `stur x?,[x?,#0xd8]`(纯正则扫字节, 44MB 一次)。
  2) 命中点归到所属函数(kallsyms 定界), 在函数内追踪 adrp/add/mov 常量, 看写入值是不是
     "链接期常量"(= 静态对象地址) —— 这就是 fake seq_file 需要的 private_data。
  3) 回查哪些 file_operations 的 +0x70(open) 槽 = 这个函数, 并列出该 fops 的 read 槽函数。
用法: PYTHONIOENCODING=utf-8 python pd_static_scan.py [min_value=0]
"""
import io, re, sys, struct, bisect, collections
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

AN = r'G:\项目\Windows管理\usb\临时root\analysis'
KS = AN + r'\kallsyms_g2a88cd145def.txt'
IMG = AN + r'\kernel_dev_g2a88cd145def.bin'
TB = AN + r'\cfi_type_tables.txt'
BASE = 0xffffffc010080000
HDR = re.compile(r'^(0x[0-9a-f]{16})\s+n=(\d+)\s*(.*)$')
strip = lambda n: n.split('$')[0].split('.')[0]
WRIT = set('bBdDw')

syms = []
for l in io.open(KS, encoding='utf-8', errors='replace'):
    p = l.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), p[1], ' '.join(p[2:])))
syms.sort()
addrs = [s[0] for s in syms]
fnaddr = {}
for a, t, n in syms:
    if t in 'tT':
        fnaddr.setdefault(strip(n), a)


def sym_at(a):
    i = bisect.bisect_right(addrs, a) - 1
    return syms[i] if i >= 0 else None


def obj_span(a):
    i = bisect.bisect_right(addrs, a)
    if i == 0 or i >= len(syms):
        return 0
    return syms[i][0] - syms[i - 1][0]


name_of_e = {}
for i, l in enumerate(io.open(TB, encoding='utf-8', errors='replace')):
    m = HDR.match(l.strip())
    if m:
        rest = l.split('  ', 1)
        names = [x.strip() for x in rest[1].split('|')] if len(rest) > 1 else []
        for idx, nm in enumerate([n for n in names if n]):
            name_of_e[int(m.group(1), 16) + 4 * idx] = strip(nm)

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
byobj = collections.defaultdict(dict)
objinfo = {}
for a, v in RELA.items():
    nm = name_of_e.get(v)
    if not nm:
        continue
    s = sym_at(a)
    if s:
        byobj[s[0]][a - s[0]] = nm
        objinfo[s[0]] = s

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True
STRD8 = re.compile(r'^str\s+(x\d+),\s*\[x(\d+),\s*#0xd8\]$')
STURD8 = re.compile(r'^stur\s+(x\d+),\s*\[x(\d+),\s*#0xd8\]$')

# ---- 1) 字节级筛出候选指令: str/stur x?, [x?, #PD]  (PD 可用 argv[1] 十六进制给定) ----
PD = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0xd8
STRD8 = re.compile(r'^str\s+(x\d+),\s*\[x(\d+),\s*#0x%x\]$' % PD)
STURD8 = re.compile(r'^stur\s+(x\d+),\s*\[x(\d+),\s*#0x%x\]$' % PD)
cand = []
imm12 = PD >> 3
if PD % 8 == 0 and 0 <= imm12 < 4096:
    want = 0xF9000000 | (imm12 << 10)
    b1 = ((imm12 & 0x3F) << 2) & 0xFC
    b2 = (imm12 >> 6) & 0x3F
    pat_re = re.compile(rb'[\x00-\xff][%c-%c]%c\xf9' % (bytes([b1]), bytes([b1 + 3]), bytes([b2])))
    for m in re.finditer(pat_re, data):
        if m.start() % 4:
            continue
        if (struct.unpack_from('<I', data, m.start())[0] & 0xFFCFFC00) == want:
            cand.append(BASE + m.start())
if 0 <= PD < 256:
    want2 = 0xF8C00000 | (PD << 12)
    c1 = ((PD & 0xF) << 4) & 0xFC
    c2 = 0xC0 | ((PD >> 4) & 0x1F)
    pat2 = re.compile(rb'[\x00-\xff][%c-%c]%c\xf8' % (bytes([c1]), bytes([c1 + 3]), bytes([c2])))
    for m in re.finditer(pat2, data):
        if m.start() % 4:
            continue
        if (struct.unpack_from('<I', data, m.start())[0] & 0xFFFFFC00) == want2:
            cand.append(BASE + m.start())
print('str/stur x?,[x?,#0x%x] 命中 %d 条' % (PD, len(cand)))

byfn = collections.defaultdict(list)
for pc in cand:
    s = sym_at(pc)
    if s:
        byfn[s[0]].append(pc)
print('落在 %d 个函数里' % len(byfn))


def trace(faddr, limit):
    o = faddr - BASE
    n = max(1, min(700, limit // 4))
    try:
        seq = list(md.disasm(data[o:o + 4 * n], faddr))
    except Exception:
        return []
    live, hits = {}, []
    for i in seq:
        full = (i.mnemonic + ' ' + i.op_str).strip()
        m = STRD8.match(full) or STURD8.match(full)
        if m:
            hits.append((i.address, m.group(1), m.group(2), live.get(m.group(1))))
            continue
        mm = re.match(r'^add\s+(x\d+),\s*(x\d+),\s*#(0x[0-9a-f]+|\d+)$', full)
        if mm and live.get(mm.group(2), ('', 0))[0] == 'adrp':
            live[mm.group(1)] = ('adrp', live[mm.group(2)][1] + int(mm.group(3), 16))
            continue
        if i.mnemonic == 'adrp':
            try:
                live[i.op_str.split(',')[0].strip()] = ('adrp', int(i.op_str.split('#')[-1], 16))
            except ValueError:
                pass
            continue
        mm = re.match(r'^mov\s+(x\d+),\s*(x\d+)$', full)
        if mm:
            live[mm.group(1)] = live.get(mm.group(2), ('unk', None))
            continue
        mm = re.match(r'^ldr\s+(x\d+),\s*\[x(\d+),\s*#(0x[0-9a-f]+)\]$', full)
        if mm:
            if live.get(mm.group(2), ('', 0))[0] == 'adrp':
                live[mm.group(1)] = ('gvar', live[mm.group(2)][1] + int(mm.group(3), 16))
            else:
                live[mm.group(1)] = ('ldr', 'x%s+%s' % (mm.group(2), mm.group(3)))
            continue
        mm = re.match(r'^ldr\s+(x\d+),\s*\[x(\d+)\]$', full)
        if mm:
            if live.get(mm.group(2), ('', 0))[0] == 'adrp':
                live[mm.group(1)] = ('gvar', live[mm.group(2)][1])
            else:
                live[mm.group(1)] = ('ldr', 'x%s+0' % mm.group(2))
            continue
        mm = re.match(r'^[a-z][a-z0-9]*\s+(x\d+)[,\]]', full)
        if mm and i.mnemonic not in ('str', 'stur', 'stp', 'sturb', 'strb', 'strh'):
            live.pop(mm.group(1), None)
    return hits


openfns = collections.defaultdict(list)
for obj, slots in byobj.items():
    if slots.get(0x70):
        openfns[slots[0x70]].append(obj)

print()
print('=== A) private_data = 链接期静态常量 的函数 ===')
rows = []
for fa, pcs in sorted(byfn.items()):
    fname = strip(sym_at(fa)[2])
    for pc, src, bas, info in trace(fa, obj_span(fa) or 0x400):
        if info and info[0] == 'adrp' and info[1] > BASE:
            rows.append((fname, fa, pc, info[1], 'adrp'))
        elif info and info[0] == 'gvar' and info[1] > BASE:
            rows.append((fname, fa, pc, info[1], 'gvar'))
uniq = {}
for r in rows:
    uniq.setdefault((r[0], r[3]), r)
for (fname, fa, pc, val, kind) in sorted(uniq.values(), key=lambda x: (x[0], x[3])):
    if kind == 'gvar':
        # val = 全局变量本身的地址; 它的链接期值 = RELA[val]
        inner = RELA.get(val)
        s2 = sym_at(val)
        s3 = sym_at(inner) if inner else None
        print('  %-30s store@%x 取用全局 %s [%s] 的运行时值 -> 链接期值=%s %s' %
              (fname[:30], pc, s2[2][:24] if s2 else hex(val), s2[1] if s2 else '?',
               hex(inner) if inner else '0/无rela',
               ('(指向 %s[%s] sz~0x%x)' % (s3[2][:24], s3[1], obj_span(s3[0]))) if s3 else ''))
        fops = openfns.get(fname, [])
        if fops:
            for o in fops:
                a, t, n = objinfo[o]
                print('        是 fops %s[%s] 的 open; read=%s' % (n[:30], t, byobj[o].get(0x10)))
        continue
    s2 = sym_at(val)
    tag = '%s @0x%x [%s] sz~0x%x' % (s2[2][:34], s2[0], s2[1], obj_span(s2[0])) if s2 else '?'
    fops = openfns.get(fname, [])
    print('  %-32s store@%x  值=0x%x -> %s' % (fname[:32], pc, val, tag))
    print('       是某些 fops 的 +0x70(open)? %s' % (['%s[%s] read=%s' %
          (objinfo[o][2][:28], objinfo[o][1], byobj[o].get(0x10)) for o in fops] or '否'))
print('  唯一 (函数,静态值) 组合 = %d' % len(uniq))
print('  其中"确为某 fops 的 .open"的:')
for (fname, fa, pc, val, kind) in sorted(uniq.values(), key=lambda x: (x[0], x[3])):
    if fname in openfns:
        print('     ★ %s  值/全局 = 0x%x (%s)' % (fname, val, kind))

print()
print('=== B) 是 fops.open 且 private_data = 间接来源(inode->i_private 等) ===')
cnt = collections.Counter()
det = collections.defaultdict(list)
for fname, objs in sorted(openfns.items()):
    if fname not in fnaddr:
        continue
    fa = fnaddr[fname]
    for pc, src, bas, info in trace(fa, obj_span(fa) or 0x400):
        if info and info[0] == 'ldr':
            for o in objs:
                a, t, n = objinfo[o]
                cnt[info[1]] += 1
                det[info[1]].append((fname, n, t, byobj[o].get(0x10), byobj[o].get(0x20)))
for src, n in cnt.most_common(25):
    print('  [%s] -> %d 个 fops, 例:' % (src, n), det[src][:4])
