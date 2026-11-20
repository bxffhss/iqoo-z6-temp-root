#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""indirect_scan.py —— 补上静态调用图的盲区: **只经 fops 间接调用到达的驱动 handler**。
根 = `ioctl165_inv.txt` 里那 165 个"app 域能打开的节点上的 ioctl handler"(本项目已实测可达),
进入它们时的累计深度 Σ_base = syscall 侧到 do_vfs_ioctl 的实测值(0x80)。
输出: 每个拷贝点(目的=sp+o)的深端、需要的最小长度 L, 以及对 GhostLock 窗口 [0x269,0x2B8] 的判定。
"""
import collections, io, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
src = io.open(os.path.join(HERE, 'stackdepth.py'), encoding='utf-8').read().split("def main():")[0]
ns = {'__file__': os.path.join(HERE, 'stackdepth.py')}
exec(compile(src, 'stackdepth', 'exec'), ns)
K = ns['K']()
name = K.name
FR = {s: K.frame(s)[0] for s in name}
addr_of = collections.defaultdict(list)
for a, n in name.items():
    addr_of[n].append(a)
adj = collections.defaultdict(list)
for c, t, pc, kind in K.edges:
    adj[c].append((t, pc, kind))
copyaddr = {a: n for a, n in name.items() if ns['is_copier'](n)}

SIGBASE = int(os.environ.get('SIGBASE', '0x80'), 16)
LO, HI = 0x269, 0x2b8
handlers = [l[4:].strip() for l in io.open(r'C:/qemu_test/ioctl165_inv.txt', encoding='utf-8')
            if l.startswith('### ')]
rows, miss = [], 0
for h in handlers:
    for sa in addr_of.get(h, []):
        if not sa: miss += 1
        stack = [(sa, SIGBASE + FR[sa], 0, ())]
        while stack:
            cur, sg, lvl, anc = stack.pop()
            for (t, pc, kind) in adj.get(cur, []):
                if t not in copyaddr: continue
                cn = copyaddr[t]
                off = K.resolve(ns['dst_reg'](cn), pc, 0, cur)
                if off is None: continue
                deep = sg - off
                if deep < 0x180 or deep > 0x600: continue
                rows.append((deep, sg, off, name[cur], cn, hex(pc), h))
            if lvl >= 6: continue
            for (t, pc, kind) in adj.get(cur, []):
                if t in anc or t not in name: continue
                ft = FR[t]
                if ft == 0: continue
                nsg = (sg - FR[cur] + ft) if kind == 'b' else (sg + ft)
                if nsg > 0x700: continue
                stack.append((t, nsg, lvl + 1, anc + (cur,)))
rows = sorted(set(rows))
print("handler 未符号化: %d, 候选点: %d  (Σ_base=0x%x, 窗口 [%s,%s])" % (miss, len(rows), SIGBASE, hex(LO), hex(HI)))
good = []
for deep, sg, off, hn, cn, pc, h in rows:
    if deep < LO or (deep - HI) % 8: continue
    need = deep - HI + 1
    good.append((deep, sg, off, hn, cn, pc, h, need))
print("深端 ≥0x2B8 且 8 对齐的候选: %d" % len(good))
for deep, sg, off, hn, cn, pc, h, need in good:
    print("  deep=0x%-5x Σ=0x%-5x o=0x%-5x 需L≥0x%-4x %-34s %-24s via %s" %
          (deep, sg, off, need, hn[:34], cn[:24], h))
io.open(os.path.join(HERE, 'indirect_dump.tsv'), 'w', encoding='utf-8').write(
    "\n".join("\t".join(x) for x in
              [map(lambda v: str(v), r) for r in rows]) + "\n")
print("全表 -> indirect_dump.tsv")
