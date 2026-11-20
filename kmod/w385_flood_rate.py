#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w385_flood_rate.py —— 一发里"打印洪水"与"fork 速率"两件事的可复跑读数器（第 138 发换来的）。

为什么要有它（md §6.294④）：格 1 的机制判读全靠两个乘数——
  ① 环形缓冲的**周转秒数**（同一份 ~2.05 MB 环覆盖多少秒的日志）＝打印量的代理；
  ② 采样曲线里的 **fork/s、ctxt/s**＝负载的代理。
这两个数以前是我在日志里现手数出来的（例 91：派生数要现算，别把措辞当读数），
所以搬成脚本：每发照跑一遍，数字由脚本出，不由我出。

用法：
  PYTHONUTF8=1 python kmod/w385_flood_rate.py --curve <w3xx_w356_storm.out> --insmod-up <X>
        [--ring <dmesg2.log 或 ksu_ring_load.txt>] [--ring2 <另一份整环>]
  自测（正/负对照，拿第 138 发的已知答案对表）：
  PYTHONUTF8=1 python kmod/w385_flood_rate.py --selftest
"""
import argparse
import os
import re
import sys

TS = re.compile(r'\[\s*(\d+\.\d+)\]')
CURVE = re.compile(r'up=([\d.]+)\s+procs=(\d+)\s+ctxt=(\d+).*?mod=(\d)\s+enf=(\d)')


def ring_coverage(path):
    """一份整环 dump ⇒ 首末时间戳、行数、周转秒数、每行的行数字节。"""
    ts = []
    n = 0
    disp = 0
    kb = 0
    with open(path, 'rb') as f:
        for raw in f:
            kb += len(raw)
            line = raw.decode('utf-8', 'replace')
            if not line.strip():
                continue
            n += 1
            if 'dispatcher entered' in line:
                disp += 1
            m = TS.match(line)
            if m:
                ts.append(float(m.group(1)))
    if len(ts) < 2:
        return None
    cov = ts[-1] - ts[0]
    return dict(first=ts[0], last=ts[-1], cov=cov, rows=n, disp=disp,
                lps=n / cov if cov else 0.0, dplps=disp / cov if cov else 0.0,
                kb=kb / 1024.0, kbps=(kb / 1024.0) / cov if cov else 0.0,
                nts=len(ts))


def curve_rows(path):
    rows = []
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            m = CURVE.search(line)
            if m:
                rows.append((float(m.group(1)), int(m.group(2)), int(m.group(3)),
                             int(m.group(4)), int(m.group(5))))
    return rows


def rate(rows, lo, hi):
    sel = [r for r in rows if lo <= r[0] <= hi]
    if len(sel) < 2:
        return None
    dt = sel[-1][0] - sel[0][0]
    if dt <= 0:
        return None
    return dict(up0=sel[0][0], up1=sel[-1][0], dt=dt,
                fork=(sel[-1][1] - sel[0][1]) / dt,
                ctxt=(sel[-1][2] - sel[0][2]) / dt,
                mod=sel[-1][3], n=len(sel))


def gaps(rows, thr=10.0):
    out = []
    for a, b in zip(rows, rows[1:]):
        if b[0] - a[0] > thr:
            out.append((a[0], b[0]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--curve')
    ap.add_argument('--insmod-up', type=float)
    ap.add_argument('--ring')
    ap.add_argument('--ring2')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.curve or a.insmod_up is None:
        print('用法见文件头；--selftest 先跑一遍')
        return 2

    print('=== 曲线 %s（参照 insmod up=%.2f）===' % (a.curve, a.insmod_up))
    rows = curve_rows(a.curve)
    if not rows:
        print('  [x] 曲线里一条都解析不到 ⇒ 探针坏了，不是没数据（例 103）')
        return 1
    print('  行数=%d 覆盖 up=%.2f~%.2f' % (len(rows), rows[0][0], rows[-1][0]))
    g = gaps(rows)
    if g:
        print('  !! 曲线空洞 >10 秒：%d 处（写者中途没跟上 ⇒ 下面的率是"平均"不是"连续"）' % len(g))
    X = a.insmod_up
    # ★窗口一律**相对 insmod 定死**(与 boot 早晚无关)，否则"装载前基线"没定义：
    #   138 一手：从曲线起点(还在开机)起算＝15.1/秒；从 [X-120,X-8] 起算＝7.1/秒。
    segs = [('基线[X-120,X-8]', X - 120, X - 8),
            ('基线[X-30,X-8]', X - 30, X - 8),
            ('装载后头 8 秒', X, X + 8),
            ('+8~+20 秒', X + 8, X + 20),
            ('末段(最后 20 秒)', rows[-1][0] - 20, rows[-1][0])]
    flip = next((r[0] for r in rows if r[4] == 0), None)
    print('  enf 翻转(=punch 落地)在 up=%s（只当信息，不当窗口边界）'
          % ('%.1f' % flip if flip else '从未发生'))
    for lab, lo, hi in segs:
        r = rate(rows, lo, hi)
        if r:
            print('  %-18s up %7.1f~%7.1f  fork/s=%6.1f  ctxt/s=%7.0f  mod=%d'
                  % (lab, r['up0'], r['up1'], r['fork'], r['ctxt'], r['mod']))
    pre = rate(rows, X - 120, X - 8)
    post = rate(rows, X, X + 8)
    if pre and post:
        print('  ⇒ **R1/R0 = %.2f**（装载后头 8 秒 ÷ 基线[X-120,X-8]；判"风暴/放大"只看这个比值，不看绝对值）'
              % (post['fork'] / pre['fork']))
    last_mod = [r for r in rows if r[3] == 1]
    print('  mod=1 的最后一格：up=%s ⇒ 距装载 %s 秒（**只是"不晚于"，不是死点**，例 99）'
          % (('%.2f' % last_mod[-1][0]) if last_mod else '无',
             ('%.1f' % (last_mod[-1][0] - X)) if last_mod else '-'))

    for lab, p in (('整环(装载快照)', a.ring), ('整环(末段覆盖)', a.ring2)):
        if not p:
            continue
        c = ring_coverage(p)
        print('=== %s %s ===' % (lab, p))
        if not c:
            print('  [x] 解析不到时间戳 ⇒ 这份文件不配当证人')
            continue
        print('  时间戳 %d 个：首=%.3f 末=%.3f ⇒ **周转/覆盖 = %.1f 秒**'
              % (c['nts'], c['first'], c['last'], c['cov']))
        print('  行数=%d（%.0f KB）⇒ %.0f 行/秒、%.0f KB/秒；其中 dispatcher=%d ⇒ %.0f 行/秒'
              % (c['rows'], c['kb'], c['lps'], c['kbps'], c['disp'], c['dplps']))
    return 0


def selftest():
    """正/负对照：拿第 138 发已写进 §6.294 的数字对表；负对照=把参照 up 挪到曲线之外，应解析不出末段。"""
    ev = 'kmod/w103_evidence/'
    curve = ev + 'w383_w356_storm.out'
    ring_load = ev + 'w383_ksu_ring_load.txt'
    ring_end = ev + 'w383_dmesg2.log'
    fails = 0
    rows = curve_rows(curve)
    X = 412.09
    pre = rate(rows, X - 120, X - 8)          # 定死相对窗口
    naive = rate(rows, rows[0][0], X - 8)      # 从曲线起点起算(错的用法，留着当对照)
    post = rate(rows, X, X + 8)
    tail = rate(rows, rows[-1][0] - 20, rows[-1][0])
    checks = [
        ('曲线解析出行(正对照)', len(rows) > 300, '%d 行' % len(rows)),
        ('基线[X-120,X-8] fork/s 在 6~9', 6 <= pre['fork'] <= 9, '%.1f' % pre['fork']),
        ('窗口一换数字就换 ⇒ 窗口边界必须随读数登记(自证这一格)', naive['fork'] > pre['fork'] * 1.3,
         '从曲线起点 %.1f vs 相对窗口 %.1f' % (naive['fork'], pre['fork'])),
        ('装载后头 8 秒 fork/s 涨到 >=25', post['fork'] >= 25, '%.1f' % post['fork']),
        ('末段 fork/s 仍在 25 以上(持续，不是尖峰)', tail['fork'] >= 25, '%.1f' % tail['fork']),
        ('装载后/装载前 比值 >=3', post['fork'] / pre['fork'] >= 3,
         '%.1fx' % (post['fork'] / pre['fork'])),
        ('mod=1 的最后一格存在', any(r[3] == 1 for r in rows), ''),
    ]
    c1 = ring_coverage(ring_load)
    c2 = ring_coverage(ring_end)
    checks += [
        ('装载快照那份覆盖 >100 秒(环里有装载期)', c1['cov'] > 100, '%.1f 秒' % c1['cov']),
        ('装载快照里 dispatcher 计数 >1000', c1['disp'] > 1000, '%d' % c1['disp']),
        ('装载快照的行/秒 < 末段的行/秒(洪水在涨)', c1['lps'] < c2['lps'],
         '%.0f < %.0f' % (c1['lps'], c2['lps'])),
        ('末段那份覆盖 < 20 秒(环被刷穿)', c2['cov'] < 20, '%.1f 秒' % c2['cov']),
        ('末段 dispatcher 行/秒 > 1000', c2['dplps'] > 1000, '%.0f' % c2['dplps']),
    ]
    # 负对照：参照挪到曲线覆盖之外 ⇒ 末段率应当拿不到
    bad = rate(rows, rows[-1][0] + 500, rows[-1][0] + 700)
    checks += [('负对照：窗口在曲线之外 ⇒ 拿不到数', bad is None, str(bad))]
    # 负对照 2：非整环文件不该被当成"计数 0 的正常读数"
    n = ring_coverage(ev + 'w383_go_run.txt') if os.path.exists(ev + 'w383_go_run.txt') else None
    checks += [('负对照：非整环文件 => 解析不出时间戳(报不配当证人)', n is None, str(n)[:30])]

    for name, cond, extra in checks:
        print('%s %-46s %s' % ('✓' if cond else '✗', name, extra))
        if not cond:
            fails += 1
    print('== %d/%d 过 ==' % (len(checks) - fails, len(checks)))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
