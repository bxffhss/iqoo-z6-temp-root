#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fake_seq_scan.py —— "假 struct seq_file 读原语"普查(离线静态, 不碰设备).

阶段:
  A. 反推本构建 file_operations 布局(只用 cfi 表 + .rela 统计, 见 fops_layout.py 的交叉验证)。
  B. 找出所有 `.read` 槽链接期就等于 seq_read 的 fops 对象 -> 这些就是"seq 读文件"。
     同时给出对象所在段(kallsyms 字母) / .open / .release / .llseek / .read_iter。
  C. 扫所有 open 类型函数, 找 `str x?,[x?,#0xd8]`(= 写 filp->private_data) 且值的来源是
       - adrp+add 常量(静态对象)  ★ 我们要的
       - [x1, #imm](inode->i_private, 值在 inode 建立时定, 需再看)
       - 某次调用的返回值(堆)  ✗
     报告目标符号 / 段字母 / 对象大小。
  D. 求 B∩C。
用法: PYTHONIOENCODING=utf-8 python fake_seq_scan.py [dump_addr]
"""
import io, re, sys, struct, bisect, collections
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

AN = r'G:\项目\Windows管理\usb\临时root\analysis'
KS = AN + r'\kallsyms_g2a88cd145def.txt'
IMG = AN + r'\kernel_dev_g2a88cd145def.bin'
TB = AN + r'\cfi_type_tables.txt'
BASE = 0xffffffc010080000
HDR = re.compile(r'^(0x[0-9a-f]{16})\s+n=(\d+)\s*(.*)$')
WRIT = set('bBdDw')                      # 可写段字母
PD = 0xd8                               # filp->private_data (seq_read+0x24 里 ldr x21,[x0,#0xd8])

strip = lambda n: n.split('$')[0].split('.')[0]

# ---------- kallsyms ----------
syms = []
for l in io.open(KS, encoding='utf-8', errors='replace'):
    p = l.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), p[1], ' '.join(p[2:])))
syms.sort()
addrs = [s[0] for s in syms]
fn_addr = {}                             # 函数名(去 $) -> (addr, type)
for a, t, n in syms:
    if t in 'tT':
        fn_addr.setdefault(strip(n), (a, t))


def sym_at(a):
    i = bisect.bisect_right(addrs, a) - 1
    return syms[i] if i >= 0 else None


def obj_span(a):
    i = bisect.bisect_right(addrs, a)
    if i == 0 or i >= len(syms):
        return 0
    return syms[i][0] - syms[i - 1][0]


# ---------- KCFI 序言 -> 函数名 ----------
groups = []
for i, l in enumerate(io.open(TB, encoding='utf-8', errors='replace')):
    m = HDR.match(l.strip())
    if m:
        rest = l.split('  ', 1)
        names = [x.strip() for x in rest[1].split('|')] if len(rest) > 1 else []
        groups.append((i + 1, int(m.group(1), 16), [n for n in names if n]))
name_of_e, entry_of, line_members = {}, collections.defaultdict(list), {}
for line, b, names in groups:
    line_members[line] = set(strip(n) for n in names)
    for idx, nm in enumerate(names):
        name_of_e[b + 4 * idx] = strip(nm)
        entry_of[strip(nm)].append(b + 4 * idx)

# ---------- .rela ----------
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
slotfn = {}                              # (obj, off) -> func name
for a, v in RELA.items():
    nm = name_of_e.get(v)
    if nm:
        slotfn[(a, nm)] = v

READ_G = line_members.get(14233, set())
OPEN_G = line_members.get(14253, set()) | line_members.get(14240, set())
ITER_G = line_members.get(14187, set())
LSEEK_G = line_members.get(12913, set())

# ---------- B: .read == seq_read 的 fops ----------
byobj = collections.defaultdict(dict)     # obj -> {off: funcname}
objinfo = {}
for a, v in RELA.items():
    nm = name_of_e.get(v)
    if not nm:
        continue
    s = sym_at(a)
    if not s:
        continue
    byobj[s[0]][a - s[0]] = nm
    objinfo[s[0]] = s
seq_fops = []
for obj, slots in byobj.items():
    if slots.get(0x10) != 'seq_read':
        continue
    a, t, n = objinfo[obj]
    seq_fops.append({'obj': obj, 'name': n, 'type': t,
                     **{('s%x' % k): v for k, v in slots.items()}})
print('=== B) .read(+0x10) 槽链接期就等于 seq_read 的静态对象 ===')
for r in sorted(seq_fops, key=lambda x: x['obj']):
    print('  %-42s @0x%016x [%s] sz~0x%x | +0x8=%s +0x10=%s +0x20=%s +0x70=%s +0x80=%s' %
          (r['name'][:42], r['obj'], r['type'], obj_span(r['obj']),
           r.get('s8'), r.get('s10'), r.get('s20'), r.get('s70'), r.get('s80')))
print('  合计 %d 个, 其中在可写段: %d' % (len(seq_fops), sum(1 for r in seq_fops if r['type'] in WRIT)))

# ---------- C: open 处理函数里 private_data = 静态对象 ----------
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True
STRD8 = re.compile(r'^str\s+(x\d+),\s*\[x(\d+),\s*#0x%x\]$' % PD)
ADR = re.compile(r'^#\*?(0x[0-9a-f]+)$')


def analyze(fn, addr, n=400):
    o = addr - BASE
    if not (0 <= o < len(data) - 4):
        return None
    try:
        seq = list(md.disasm(data[o:o + 4 * n], addr))
    except Exception:
        return None
    live = {}       # reg -> ('imm', value) or ('adrp', page) or ('sym', name)
    hits = []
    calls = []
    for i in seq:
        mn, ops = i.mnemonic, i.op_str
        full = (mn + ' ' + ops).strip()
        m = STRD8.match(full)
        if m:
            src, bas = m.group(1), m.group(2)
            hits.append((i.address, src, bas, live.get(src)))
        mm = re.match(r'^(?:add)\s+(x\d+),\s*(x\d+),\s*#(0x[0-9a-f]+|\d+)$', full)
        if mm and mm.group(2) in live and live[mm.group(2)][0] == 'adrp':
            base_v = live[mm.group(2)][1] + int(mm.group(3), 16)
            live[mm.group(1)] = ('adrp', base_v)
            continue
        if mn == 'adrp':
            t = ops.split('#')[-1].strip()
            try:
                live[ops.split(',')[0].strip()] = ('adrp', int(t, 16))
            except ValueError:
                live.pop(ops.split(',')[0].strip(), None)
            continue
        mm = re.match(r'^mov\s+(x\d+),\s*(x\d+)$', full)
        if mm:
            live[mm.group(1)] = live.get(mm.group(2), ('?', None))
            continue
        mm = re.match(r'^ldr\s+(x\d+),\s*\[x(\d+),\s*#(0x[0-9a-f]+)\]$', full)
        if mm:
            live[mm.group(1)] = ('ldr', 'x%s+%s' % (mm.group(2), mm.group(3)))
            continue
        if mn in ('bl', 'b') and ops.startswith('#'):
            t = re.search(r'#(0x[0-9a-f]+)', ops)
            if t:
                s = sym_at(int(t.group(1), 16))
                if s:
                    calls.append(strip(s[2]))
                    if s[2].startswith('bl '):
                        pass
            live['x0'] = ('call', calls[-1] if calls else '?')
            continue
        d = re.match(r'^(?:[a-z][a-z0-9]*)\s+(x\d+)\b', ops)
        if d and mn not in ('str', 'stp', 'stur'):
            if not (m and d.group(1) == m.group(1)):
                live.pop(d.group(1), None)
    return hits, calls


print()
print('=== C) open 类型函数中把 filp->private_data 设为静态对象的 ===')
static_opens = {}
cand = sorted(set([nm for nm in fn_addr if nm in OPEN_G and (nm.endswith('_open') or nm.endswith('open'))]) |
              set(nm for nm in fn_addr if nm in OPEN_G and nm.endswith('_release')))
allnames = set()
for line, b, names in groups:
    for nm in names:
        allnames.add(strip(nm))
opens = sorted(set(n for n in allnames if n in fn_addr and n in OPEN_G) |
               set(s.get(0x70) for s in byobj.values() if s.get(0x70)))
print('  (待扫 open/release 类型函数 + 所有 fops 的 +0x70 槽函数: %d 个)' % len(opens))
for nm in opens:
    if nm not in fn_addr:
        continue
    a, t = fn_addr[nm]
    r = analyze(nm, a)
    if not r:
        continue
    hits, calls = r
    static = []
    for pc, src, bas, info in hits:
        if info and info[0] == 'adrp' and info[1]:
            s = sym_at(info[1])
            static.append((pc, info[1], s, obj_span(info[1]) if s else 0))
        elif info and info[0] == 'ldr':
            static.append((pc, ('i_private?' + info[1]), None, 0))
    if static:
        static_opens[nm] = (a, static, calls)
        for pc, v, s, sz in static:
            if s:
                print('  %-32s @0x%x  str->0x%x  [%s @0x%x 段%s sz~0x%x]' %
                      (nm[:32], a, pc, s[2][:34], s[0], s[1], sz))
            else:
                print('  %-32s @0x%x  str-> 间接 %s' % (nm[:32], a, v))
print('  小计: open 组成员 %d, 有静态/i_private 写入的 %d' % (len(opens), len(static_opens)))

# ---------- D: 交集 ----------
print()
print('=== D) 交集: fops.read=seq_read 且 fops.open 给静态 private_data ===')
byname_fops = collections.defaultdict(list)
for r in seq_fops:
    byname_fops[r.get('s70')].append(r)
hit = 0
for fn in sorted(set(byname_fops) & set(static_opens)):
    for r in byname_fops[fn]:
        print('  ★ %s  open=%s  private_data 目标=%s' % (r['name'], fn, static_opens[fn][1]))
        hit += 1
print('  交集 = %d' % hit)
if len(sys.argv) > 1:
    a = int(sys.argv[1], 16)
    print('--- dump 0x%x 前 0x90 字节(镜像原值) ---' % a)
    for o in range(0, 0x90, 8):
        v = struct.unpack_from('<Q', data, a + o - BASE)[0] if a + o - BASE < len(data) else 0
        print('  +0x%-4x %016x  rela=%s' % (o, v, hex(RELA.get(a + o, 0))))
