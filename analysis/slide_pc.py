# -*- coding: utf-8 -*-
"""slide_pc.py — 用**正对照**求本次开机的 KASLR slide(不靠"热点名字像不像")。

前提: 采样必须来自**采样器自己的** syscall 循环(perfips 就是自采样), 这样"内核里
一定走过这几个窄函数"是**构造性事实**, 不需要猜工作负载。

判据: 下面这些函数的链接期地址+宽度都是**已知且很窄**的(合计 ~4 KB),
而整段 text 是 21 MB ⇒ 随机放一个 slide, 400 个样本落进这 4 KB 的期望值 ≈ 0.08 个。
所以"命中数"的峰就是答案, 其它候选只能是噪声。
★ 不用 el0_sync/ret_to_user 这类**向量页**里的地址: 它们在运行时是另一套映射,
  按 _text+slide 去对会永远 0 命中(9/27 就在这上面误判过一次"候选全错")。

用法: python analysis/slide_pc.py <ips.txt> [--print-only]
      命中不足 3 个 ⇒ 打印 NOSLIDE 并以 exit 2 结束(绝不猜)。
"""
import bisect, io, re, sys

KS = r'G:\项目\Windows管理\usb\临时root\analysis\kallsyms_g2a88cd145def.txt'
TEXT = 0xffffffc010080000
ETEXT = 0xffffffc0115a0000
STEP = 0x200000                       # KASLR 以 2MB 为步长

# 正对照函数(纯靠 syscall 循环就一定会碰到)
CTRL = ['el0_svc', 'el0_svc_common', '__arm64_sys_getpid', '__arm64_sys_getppid',
        '__arm64_sys_newuname', '__arm64_sys_newfstat', 'vfs_statx', 'link_path_walk',
        '__arm64_sys_getdents64', 'user_path_at']


def load():
    syms = []
    for line in io.open(KS, encoding='utf-8', errors='replace'):
        p = line.split()
        if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
            syms.append((int(p[0], 16), ' '.join(p[2:])))
    syms.sort()
    return syms


def main():
    f = sys.argv[1]
    ips = []
    for line in io.open(f, encoding='utf-8', errors='replace'):
        m = re.search(r'([0-9a-f]{12,16})\s*$', line.strip())
        if m:
            v = int(m.group(1), 16)
            if v >= 0xffff000000000000:      # 高半区(核文本/模块/vmalloc)都收, 主簇再分
                ips.append(v)
    ips = sorted(set(ips))
    if len(ips) < 50:
        print('NOSLIDE 样本太少 %d' % len(ips)); sys.exit(2)
    # 主簇 = 核 text 那一坨(模块/vmalloc 在别处)
    cl, cur = [], [ips[0]]
    for a, b in zip(ips, ips[1:]):
        if b - a <= 0x400000:
            cur.append(b)
        else:
            cl.append(cur)
            cur = [b]           # ★ 必须新建列表: cur.clear() 会把刚 append 进 cl 的那个也清空
    cl.append(cur)
    big = max(cl, key=len)
    S = load()
    A = [a for a, n in S]
    win = []
    for nm in CTRL:
        for i, (a, n) in enumerate(S):
            if n == nm and i + 1 < len(S):
                win.append((a, min(S[i + 1][0] - a, 0x700), nm))
                break
    tot = sum(w[1] for w in win)
    print('样本 %d(主簇 %d, [%x, %x]); 正对照窗口 %d 个合计 %#x 字节'
          % (len(ips), len(big), big[0], big[-1], len(win), tot))
    lo = (big[-1] - ETEXT) // STEP * STEP - STEP * 6
    hi = (big[0] - TEXT) // STEP * STEP + STEP * 6
    res, s = [], lo
    while s <= hi:
        det = [(nm, sum(1 for a in ips if a0 + s <= a < a0 + s + ln)) for a0, ln, nm in win]
        res.append((sum(c for _, c in det), s, det))
        s += STEP
    res.sort(key=lambda x: -x[0])
    print('扫了 %d 档 2MB 对齐 slide; top 5:' % len(res))
    for score, s, det in res[:5]:
        keep = sorted(a for a in big if TEXT + s <= a < ETEXT + s)
        print('  slide=+%-12x 正对照命中=%3d  主簇落在 text 内=%3d/%d  %s'
              % (s, score, len(keep), len(big),
                 ' '.join('%s:%d' % (n.replace('__arm64_sys_', 'sys_'), c)
                          for n, c in det if c)))
    best = res[0]
    if best[0] < 3:
        print('NOSLIDE 正对照太弱(最高只有 %d 个命中) ⇒ 不猜' % best[0]); sys.exit(2)
    if len(res) > 1 and res[1][0] * 2 >= best[0]:
        print('NOSLIDE 第二名(%d)与第一名(%d)太接近 ⇒ 不猜' % (res[1][0], best[0]))
        sys.exit(2)
    print('SLIDE %x' % best[1])


main()
