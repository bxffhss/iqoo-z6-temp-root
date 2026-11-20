#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rd_oracle_scan.py —— 在所有 fops 的 .read/.read_iter 处理函数里找"从 private_data 直接
   拷贝给用户态"的读原语(simple_read_from_buffer / memory_read_from_buffer / copy_to_user),
   并给出 avail 常量 + open 函数 + private_data 的来源类别。
   (这是 fake-seqfile 失败后的备选: "有界读 oracle")
用法: PYTHONIOENCODING=utf-8 python rd_oracle_scan.py
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
    return 0 if i == 0 or i >= len(syms) else syms[i][0] - syms[i - 1][0]


name_of_e = {}
for i, l in enumerate(io.open(TB, encoding='utf-8', errors='replace')):
    m = HDR.match(l.strip())
    if m:
        rest = l.split('  ', 1)
        names = [strip(x.strip()) for x in rest[1].split('|')] if len(rest) > 1 else []
        for idx, nm in enumerate([n for n in names if n]):
            name_of_e[int(m.group(1), 16) + 4 * idx] = nm

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
    s = sym_at(a) if nm else None
    if s:
        byobj[s[0]][a - s[0]] = nm
        objinfo[s[0]] = s

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True
SRF = fnaddr.get('simple_read_from_buffer')
MRF = fnaddr.get('memory_read_from_buffer')
CTU = fnaddr.get('_copy_to_user')
PDLD = re.compile(r'^ldr\s+(x\d+),\s*\[x\d+,\s*#0xd8\]$')


def analyze(fa, limit):
    o = fa - BASE
    n = max(1, min(500, limit // 4))
    try:
        seq = list(md.disasm(data[o:o + 4 * n], fa))
    except Exception:
        return []
    live, out = {}, []
    for i in seq:
        full = (i.mnemonic + ' ' + i.op_str).strip()
        if i.mnemonic in ('bl', 'b') and full.split()[-1].startswith('#'):
            tv = int(full.split('#')[-1], 16)
            if tv in (SRF, MRF):
                out.append(('bl ' + ('simple_read_from_buffer' if tv == SRF else 'memory_read_from_buffer'),
                            dict(x3=live.get('x3'), x4=live.get('x4'))))
            elif tv == CTU:
                out.append(('bl _copy_to_user', dict(x1=live.get('x1'), x2=live.get('x2'))))
            live = {}
            continue
        m = PDLD.match(full)
        if m:
            live[m.group(1)] = ('pd', None)
            continue
        mm = re.match(r'^mov\s+(x\d+),\s*(x\d+)$', full)
        if mm:
            live[mm.group(1)] = live.get(mm.group(2), ('unk', None))
            continue
        mm = re.match(r'^add\s+(x\d+),\s*(x\d+),\s*#(0x[0-9a-f]+|\d+)$', full)
        if mm:
            v = live.get(mm.group(2))
            live[mm.group(1)] = ('pd+' + mm.group(3), None) if v and v[0] == 'pd' else ('unk', None)
            continue
        if i.mnemonic == 'adrp':
            try:
                live[i.op_str.split(',')[0].strip()] = ('adrp', int(i.op_str.split('#')[-1], 16))
            except ValueError:
                pass
            continue
        mm = re.match(r'^(?:ldr|mov)\s+(w\d+),\s*#(0x[0-9a-f]+|\d+)$', full)
        if mm:
            live['x' + mm.group(1)[1:]] = ('imm', int(mm.group(2), 16))
            continue
        mm = re.match(r'^movk\s+(w\d+),\s*#(0x[0-9a-f]+|\d+),\s*lsl\s*#(\d+)$', full)
        if mm:
            live['x' + mm.group(1)[1:]] = ('imm?', None)
            continue
        mm = re.match(r'^[a-z][a-z0-9]*\s+(x\d+)[,\]]', full)
        if mm and i.mnemonic not in ('str', 'stp', 'stur'):
            live.pop(mm.group(1), None)
    return out


print('=== fops.read/read_iter 中 "源 = file->private_data" 的读处理函数 ===')
hits = []
seen = set()
for obj, slots in sorted(byobj.items()):
    for off in (0x10, 0x20):
        f = slots.get(off)
        if not f or f in seen or f not in fnaddr:
            continue
        seen.add(f)
        fa = fnaddr[f]
        for tag, args in analyze(fa, obj_span(fa) or 0x300):
            key = [k for k, v in args.items() if v and v[0].startswith('pd')]
            if key:
                hits.append((obj, f, tag, key, args))
for obj, f, tag, key, args in hits:
    a, t, n = objinfo[obj]
    print('  %-30s fops=%s[%s] @0x%x | %s | %s=%s | open=%s llseek=%s' %
          (f[:30], n[:26], t, a, tag, key[0], args[key[0]], slots_of := byobj[obj].get(0x70),
           byobj[obj].get(0x8)))
print('  命中 %d' % len(hits))
