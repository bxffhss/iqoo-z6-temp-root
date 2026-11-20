#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w406_setdiff.py —— 复核 §6.325 那句"死/活两发装载期内核打印**形状集合**相同"，并要求两侧带内行数都非 0 才允许谈集合。

为什么要有它：
  1) §6.325 是"不再打对照枪、直接收口"的直接依据，而它的比较是一次性脚本做的、没留可复跑产物；
  2) `dmesg.live` 由 `/proc/kmsg` 落盘、每行带 `<6>` 优先级前缀 ⇒ 任何**行首锚定**的解析都会恒数 0（例 121，
     `w404_tokcount.py` 就栽在这里）。这类比较必须用 search，并且把"某一侧带内行数＝0"当**废结论**拦下来。

配对规矩（★最容易错的地方）：整环 dump 在两类文件里都有——`*_ksu_ring_load.txt`（insmod 刚返回那刻 root 侧自己
`dmesg >` 的那份）与 `*_ksu_ring_load_mid.txt`（有的发只存了 mid 那份）。**同一时刻的那一份才能互配**：
19 发只有 `ring_load`、21 发只有 `ring_load_mid`，所以 §6.325 的配对是跨文件名的；连续件/轮转件两侧采集不对称
（本项目实测：同一窗口死发 4376 行 vs 活发 10472 行，各自"独有"的都是 init 那批行）⇒ 只当覆盖参考，不当差集依据。

用法：
  PYTHONUTF8=1 python kmod/w406_setdiff.py --self
  PYTHONUTF8=1 python kmod/w406_setdiff.py <证据目录> <DEAD:prefix>@<up>[#文件后缀] <ALIVE:...> ...
"""
import io
import os
import re
import sys
import collections

TS_RE = re.compile(r'\[\s*(\d+)\.\d+\]')
WIN = 245
DEFAULT_KIND = [('环头件', 'ksu_ring_load.txt'), ('环头件mid', 'ksu_ring_load_mid.txt'),
                ('连续件', 'dmesg.live'), ('轮转件', 'dmesg2.log')]
# 仪器自身打的行：★筛的是**归一化之后**的形状——`comm=w184_sample.sh` 归一化成 `comm=wN_sample.sh`，
#   按原文 'w184_sample.sh' 筛永远筛不到（例 98：拿原文词去筛已归一化的文本）
INSTRUMENT = ('_sample.sh', 'HB up=')


def norm(line):
    s = re.sub(r'[0-9a-fA-F]{6,}', 'HEX', line)
    return re.sub(r'\d+', 'N', s).strip()


def band(path, lo, hi):
    rows = []
    if not os.path.exists(path):
        return rows
    for l in io.open(path, encoding='utf-8', errors='replace').read().splitlines():
        m = TS_RE.search(l)                      # ★search，不是 match
        if m and 'KernelSU:' in l and lo <= int(m.group(1)) <= hi:
            rows.append((norm(l), l))
    return rows


def shape_set(pdir, prefix, up, suffix):
    lo = int(float(up)) - 2
    rows = band(os.path.join(pdir, '%s_%s' % (prefix, suffix)), lo, lo + WIN + 2)
    c = collections.Counter(s for s, _ in rows)
    ex = {}
    for s, l in rows:
        ex.setdefault(s, l[:190])
    return len(rows), c, ex


def parse(spec):
    pre, _, up = spec.partition('@')
    suffix = None
    if '#' in pre:
        pre, suffix = pre.split('#')
    return pre, up, suffix


def run(pdir, ds, as_):
    dp, du, dsuf = parse(ds)
    ap, au, asuf = parse(as_)
    kinds = [(s, s) for s in ([dsuf] if dsuf else [k for _, k in DEFAULT_KIND])]
    print('=== 死=%s@%s#%s ↔ 活=%s@%s#%s（窗口＝各 insmod-2 .. +245 秒）===' % (
        dp, du, dsuf or '全部', ap, au, asuf or '同名'))
    for suf, _ in kinds:
        n1, c1, e1 = shape_set(pdir, dp, du, suf)
        n2, c2, e2 = shape_set(pdir, ap, au, asuf or suf)
        only_d = sorted(set(c1) - set(c2))
        only_a = sorted(set(c2) - set(c1))
        only_a_k = [x for x in only_a if not any(t in x for t in INSTRUMENT)]
        print('  [%s ↔ %s] 带内行数 死=%d 活=%d ｜形状 死=%d 活=%d' % (suf, asuf or suf, n1, n2, len(c1), len(c2)))
        if n1 == 0 or n2 == 0:
            print('    ▲有一侧＝0 行 ⇒ 这份件不能用来谈"集合相同/不同"（例 112/121），下面几行只是覆盖报告')
        print('    只在死发 %d 条；只在活发 %d 条（剔除仪器行后 %d 条）' % (len(only_d), len(only_a), len(only_a_k)))
        for x in only_d[:4]:
            print('       D| %s' % e1[x])
        for x in only_a_k[:4]:
            print('       A| %s' % e2[x])


def selfcheck():
    pdir = os.path.dirname(os.path.abspath(__file__))
    ev = os.path.join(pdir, 'w103_evidence')
    ok = True
    # ①夹具＝生产件真实行形状（`<6>` 前缀）：窗口腿必须数到带内那 2 行、且不带出带外那行
    import tempfile
    d = tempfile.mkdtemp()
    fp = os.path.join(d, 'wFIX_ksu_ring_load.txt')
    with io.open(fp, 'w', encoding='utf-8', newline='\n') as f:
        f.write('<6>[  100.100000] KernelSU: KSUBEAT SD1 decline: uid=0 是 system uid\n')
        f.write('<6>[  200.500000] KernelSU: KSUBEAT F2 redirect: id=221 -> 42\n')
        f.write('<6>[  999.500000] KernelSU: KSUBEAT OUT out-of-band\n')
        f.write('<6>[  150.000000] KernelSU: KSUBEAT BN dispatcher entered: pid=2 comm=w184_sample.sh\n')
    n, c, _ = shape_set(d, 'wFIX', '100.1', 'ksu_ring_load.txt')
    print('[self] ①`<6>` 前缀夹具 带内行数=%d（期望 3＝100.1/150/200.5，带外那行 999.5 不算）形状含 OUT? %s' % (n, 'OUT' in ' '.join(c)))
    if n != 3 or any('OUT' in x for x in c):
        ok = False
    # ①b 仪器行的筛子必须筛**归一化后的形状**：`comm=w184_sample.sh` 会变成 `comm=wN_sample.sh`，按原文筛＝没牙
    inst = [x for x in c if any(t in x for t in INSTRUMENT)]
    orig = [x for x in c if 'w184_sample.sh' in x]
    print('[self] ①b 仪器形状按归一化筛到 %d 条／按原文筛到 %d 条（必须 1 与 0）' % (len(inst), len(orig)))
    if len(inst) != 1 or len(orig) != 0:
        ok = False
    # ②正对照（真件）：19 发那份整环 dump 必须非空，且与 §6.325 记的 433 对得上
    n2, c2, _ = shape_set(ev, 'w401', '666.89', 'ksu_ring_load.txt')
    print('[self] ②w401 环头件 带内行数=%d（§6.325 记 433）形状=%d' % (n2, len(c2)))
    if n2 == 0 or len(c2) == 0:
        ok = False
    # ③反夹具：不存在的发必须数到 0（比较时由 run() 把它标成"不能用"，不许读成"集合相同"）
    n3, _, _ = shape_set(ev, 'wZZZ', '1.0', 'ksu_ring_load.txt')
    print('[self] ③不存在的件 带内行数=%d（必须 0）' % n3)
    if n3 != 0:
        ok = False
    # ④这条夹具必须有牙：同一批行用行首锚定(match)数＝0 ⇒ 证明它能抓住例 121 那个 bug（"不加就坏"）
    bad = [l for l in io.open(fp, encoding='utf-8').read().splitlines()
           if (lambda m: m and 98 <= int(m.group(1)) <= 346)(TS_RE.match(l))]
    print('[self] ④同一夹具改用 match(锚定行首) 数到 %d（必须 0，否则夹具没牙）' % len(bad))
    if len(bad) != 0:
        ok = False
    print('[self] %s' % ('PASS（生产件行形状能数到＋正对照非空＋反夹具为 0）' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    a = sys.argv[1:]
    if not a or '--self' in a:
        sys.exit(selfcheck())
    run(a[0], a[1], a[2])
    sys.exit(0)
