#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w408_prune_audit.py —— 把历史上每一发"记录留在表里(prune uid=0)"的判读**按证人来源**重新分三级。

为什么要它：`prune uid`＝0 有三种完全不同的含义(例 112/118/122)——
  (甲) 这份件盖住了装载那一刻、且同批必打的 `load_allow_uid` 真在里面 ⇒ **有效反证人**；
  (乙) 这份件自称覆盖到、但同批必打的 `load_allow_uid` 不在 ⇒ 采集漏抓 ⇒ **0 无效**；
  (丙) 这份件根本没盖到装载那一刻(或它是 2 MB 定长轮转件) ⇒ **0 无效**。
⇒ 只有 (甲) 允许写"记录真留在表里"；(乙)(丙) 只能写"没测到"。

用法：PYTHONUTF8=1 python kmod/w408_prune_audit.py [--self]
"""
import io
import os
import re
import sys
import glob
import collections

EV = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'w103_evidence')
TS = re.compile(r'\[\s*(\d+)\.(\d+)\]')
CLASSES = [('环头件', 'ksu_ring_load.txt'), ('环头件mid', 'ksu_ring_load_mid.txt'),
           ('连续件', 'dmesg.live'), ('轮转件', 'dmesg2.log')]
ROT = 2 * 1024 * 1024


def rows(path):
    if not os.path.exists(path):
        return None
    return io.open(path, encoding='utf-8', errors='replace').read().splitlines()


def tsv(l):
    m = TS.search(l)
    return int(m.group(1)) + int(m.group(2)[:6]) / 10 ** 6 if m else None


def judge(path, insmod):
    """对一份件的行集合做三级判定。"""
    if not os.path.exists(path):
        return None
    ls = io.open(path, encoding='utf-8', errors='replace').read().splitlines()
    n_la = sum('load_allow_uid' in l for l in ls)
    n_pr = sum('prune uid' in l for l in ls)
    band = [l for l in ls if (t := tsv(l)) is not None and insmod - 3 <= t <= insmod + 5]
    return {'la': n_la, 'pr': n_pr, 'band': len(band), 'rot': os.path.getsize(path) >= ROT - 4096}


def cls(v):
    if v is None:
        return '缺件', ''
    if v['pr'] > 0:
        return '甲(有阳性：prune 真出现)', 'prune=%d' % v['pr']
    if v['la'] > 0 and v['band'] > 0:
        return '甲(有效反证人：la 在且带内有行)', 'la=%d band=%d' % (v['la'], v['band'])
    if v['band'] > 0 and v['la'] == 0:
        return '乙(带内有行但必打的 la 没抓到 ⇒ 0 无效)', 'band=%d' % v['band']
    return '丙(没盖到装载那一刻%s ⇒ 0 无效)' % ('／轮转件' if v['rot'] else ''), 'band=%d' % v['band']


def shots():
    out = {}
    for p in sorted(glob.glob(os.path.join(EV, 'w*_ksu_stage.log'))):
        tag = os.path.basename(p).split('_')[0]
        ls = rows(p) or []
        up = None
        for l in ls:
            m = re.search(r'insmod rc=\d+ up=([\d.]+)', l)
            if m:
                up = float(m.group(1))
                break
        if up is None:
            continue
        d = {}
        for name, suf in CLASSES:
            v = judge(os.path.join(EV, '%s_%s' % (tag, suf)), up)
            if v:
                d[name] = v
        stage_la = sum('load_allow_uid' in l for l in ls)
        stage_pr = sum('prune uid' in l for l in ls)
        out[tag] = (up, d, stage_la, stage_pr)
    return out


def main():
    S = shots()
    print('%-6s %-9s %-46s %s' % ('发', 'insmod', '可当"记录留在表里"的来源(三级判定)', 'stage 转录 la/pr'))
    for tag, (up, d, sla, spr) in sorted(S.items()):
        good = [k for k, v in d.items() if cls(v)[0].startswith('甲')]
        weak = [k + cls(v)[0][:1] for k, v in d.items() if not cls(v)[0].startswith('甲')]
        print('%-6s %-9.2f 甲=%-22s 非甲=%-26s stage=%d/%d' % (
            tag, up, ','.join(good) or '无', ','.join(weak) or '无', sla, spr))
        for k, v in d.items():
            c, det = cls(v)
            print('        [%s] %s ｜%s' % (k, c, det))
    # ★自测(正对照必须响)：已知被 prune 的 148/151/154 与已知"甲级留在表里"的 19/21
    if '--self' in sys.argv:
        want_pr = {'w393', 'w396', 'w399'}
        ok = True
        for t in want_pr:
            if t not in S:
                print('[self] 缺 %s(命名对不上?)' % t); ok = False; continue
            if not any(v['pr'] > 0 for v in S[t][1].values()):
                print('[self] %s 没数到 prune ⇒ 审计读错了件' % t); ok = False
        print('[self] 三发阳性(148/151/154)对照 %s' % ('OK' if ok else 'FAIL'))
        sys.exit(0 if ok else 1)


main()
