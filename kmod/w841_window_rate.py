#!/usr/bin/env python
# w841_window_rate.py —— 把 w810 的 CSV 折成"每秒速率"，并**现场**核对空窗基线与开窗段的差。
#   为什么要它：w810 落的是累计计数(/proc/stat 的 tick、fork、ctxt、我们 ko 的 fired#)，
#   直接看累计数会把"这一窗到底吃了多少 CPU"读成一句话——必须逐区间做差才有可比对象。
import csv, sys

path = sys.argv[1]
base = float(sys.argv[2]) if len(sys.argv) > 2 else 2.12   # 空窗基线 busy%(§6.435 实测)
rows = list(csv.reader(open(path, encoding='utf-8', errors='replace')))
h = rows[0]
d = [dict(zip(h, r)) for r in rows[1:]]
prev = None
print(f"{'up':>9} {'状态':>5} {'fork/s':>7} {'ctxt/s':>8} {'busy%':>7} {'在用核':>6} {'fired/s':>9} {'KILLSOFT':>9} {'crash':>6}")
for x in d:
    if x['up'] == 'GONE':
        prev = None
        print(f"{'-':>9} {'GONE':>5}   (adb 掉线，记为事件)")
        continue
    if x['cpu_ticks'] in ('', '?'):
        continue
    t = [int(v) for v in x['cpu_ticks'].split(',')]
    up = float(x['up'])
    fr = int(x['fork_processes'] or 0)
    ct = int(x['ctxt'] or 0)
    fi = int(x['fired'] or 0)
    if prev:
        pu, pf, pfr, pct_, pfi = prev
        dt = up - pu
        if dt <= 0:
            prev = (up, t, fr, ct, fi)
            continue
        busy = sum(t[i] - pf[i] for i in (0, 1, 2, 4, 5, 6, 7))
        idle = t[3] - pf[3]
        pct = 100.0 * busy / (busy + idle)
        st = '开窗' if x['mod'] == '1' else '空窗'
        print(f"{up:>9.1f} {st:>5} {(fr-pfr)/dt:>7.1f} {(ct-pct_)/dt:>8.0f} {pct:>6.2f}% "
              f"{pct/100*8:>6.2f} {(fi-pfi)/dt:>9.0f} {x['killssoft']:>9} {x['crash_lines']:>6}")
        if x['mod'] == '1' and pct > base * 2:
            print(f"          └ 相对空窗基线 {base}%：×{pct/base:.1f}（同 boot 自比，别记绝对阈值）")
    prev = (up, t, fr, ct, fi)
