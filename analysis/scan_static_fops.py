#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scan_static_fops.py —— "假 seq_file 读原语"的静态普查(离线, 无设备).

要做的事:
  1) 用 cfi_type_tables.txt 把"每个静态指针槽位 -> 它指向哪个函数"这张表建起来
     (槽位值 = 该函数在 .text.cfi_jt 里的序言地址 = 组首 + 4*组内下标)。
  2) 用槽位偏移的统计直方图**反推本构建的 struct file_operations 布局**
     (read / read_iter / open / release / llseek / poll 各在 +几)。
  3) 列出所有 `.read` 已经是 seq_read(或同组读函数) 的 file_operations 对象,
     并给出它们的 `.open` 函数名 + 对象所在段(kallsyms 类型字母)。
  4) 扫全部 open 类型函数, 找"把 filp->private_data(+0xd8) 设成**静态可寻址对象**"的,
     报告目标对象地址/段/大小。
  5) 求交集 = 我们要的"假 seq_file 落点"。
用法: PYTHONIOENCODING=utf-8 python scan_static_fops.py [stage]
"""
import io, re, sys, struct, bisect, collections
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

AN = r'G:\项目\Windows管理\usb\临时root\analysis'
KS = AN + r'\kallsyms_g2a88cd145def.txt'
IMG = AN + r'\kernel_dev_g2a88cd145def.bin'
TB = AN + r'\cfi_type_tables.txt'
BASE = 0xffffffc010080000
HDR = re.compile(r'^(0x[0-9a-f]{16})\s+n=(\d+)\s*(.*)$')
JT_LO, JT_HI = 0xffffffc01156a000, 0xffffffc011592000      # .text.cfi_jt 范围(实测)


def strip_hash(n):
    return n.split('$')[0].split('.')[0]


# ---------- 符号表 ----------
syms = []        # (addr, type, name)
for l in io.open(KS, encoding='utf-8', errors='replace'):
    p = l.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), p[1], ' '.join(p[2:])))
syms.sort()
addrs = [s[0] for s in syms]
byname = collections.defaultdict(list)
for a, t, n in syms:
    byname[n].append((a, t))


def sym_at(a):
    i = bisect.bisect_right(addrs, a) - 1
    return syms[i] if i >= 0 else None


def obj_size(a):
    i = bisect.bisect_right(addrs, a)
    if i >= len(syms) or i == 0:
        return 0
    return syms[i][0] - syms[i - 1][0]


# ---------- KCFI 序言地址表 ----------
def load_groups():
    groups = []
    for i, l in enumerate(io.open(TB, encoding='utf-8', errors='replace')):
        m = HDR.match(l.strip())
        if not m:
            continue
        rest = l.split('  ', 1)
        names = [x.strip() for x in rest[1].split('|')] if len(rest) > 1 else []
        groups.append((i + 1, int(m.group(1), 16), [n for n in names if n]))
    return groups


name_of_e = {}          # entry addr -> func name (原样)
entry_of = collections.defaultdict(list)
for line, b, names in load_groups():
    for idx, nm in enumerate(names):
        e = b + 4 * idx
        name_of_e[e] = nm
        entry_of[strip_hash(nm)].append((e, line, idx))

data = io.open(IMG, 'rb').read()

# ---------- .rela 解码 ----------
SYM_LAST = addrs[-1]
RELA = {}
pat = struct.pack('<Q', 1027)                     # R_AARCH64_RELATIVE
pos = 0
while True:
    k = data.find(pat, pos)
    if k < 0:
        break
    if k % 8 == 0:
        off = struct.unpack_from('<Q', data, k - 8)[0]      # r_offset (链接期绝对地址)
        add = struct.unpack_from('<Q', data, k + 8)[0]      # r_addend  = 指针值
        if BASE < off < SYM_LAST + 0x400000:
            RELA[off] = add
    pos = k + 1
print('rela 条目 = %d' % len(RELA), file=sys.stderr)

slotfn = {}             # (obj_addr, off) -> func name   [KCFI 指针槽]
for a, v in RELA.items():
    nm = name_of_e.get(v)
    if nm is None:
        continue
    s = sym_at(a)
    if not s:
        continue
    slotfn[(s[0], a - s[0])] = (nm, s[1], s[2], v)

# ---------- 2) 槽位偏移直方图 ----------
groups = load_groups()
G = {line: (b, [strip_hash(n) for n in names]) for line, b, names in groups}


def members(line):
    return set(G[line][1])


def hist(target_names, label):
    c = collections.Counter()
    for (o, off), (fn, t, nm, v) in slotfn.items():
        if fn in target_names:
            c[off] += 1
    print('--- %s 出现的槽位偏移 top ---' % label)
    for off, n in c.most_common(12):
        print('   +0x%-4x  %d 处' % (off, n))
    return c


rd = hist(members(14233), '.read 类型组(line14233, n=%d)' % len(G[14233][1]))
op = hist(members(14253), 'open/release 类型组(line14253, n=%d)' % len(G[14253][1]))
it = hist(members(14187), 'read_iter/write_iter 类型组(line14187, n=%d)' % len(G[14187][1]))
lk = hist(members(12913), 'llseek 类型组(line12913, n=4)')
print('SEQ_READ entry =', entry_of.get('seq_read'), file=sys.stderr)
