#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""slide.py —— 从 shell 自采样 perf 的内核 IP 列表反解**本次开机**的 KASLR slide。

为什么以前算不出、现在算得出:
  * 判据不能用"IP 落在某符号区间内" —— 符号区间铺满 text ⇒ 任何候选都通过(恒真)。
  * 也不能用"是不是合法指令" —— 镜像里 99.7% 的 text 字都是合法指令, 平移后仍合法。
  * 真正有判别力的是两件事的**合取**:
      (1) 主簇(核内核 text, 连续、宽≈_etext-_text)整体平移后必须仍在 text 内 ⇒ 候选只剩个位数;
      (2) 用"热点函数是否合理"定最终一名(错位 2MB 的候选会把 kfree/slab/avc 这类热点
          映射到 find_busiest_group/inet6_addr_modify 这种不可能这么热的函数上)。
  * 且这一切要求**与设备逐字同构建**的 kallsyms+Image(项目 #11 已拿到)。

用法:
  adb shell /data/local/tmp/perfips 25 > C:/qemu_test/ips_dev.txt
  python slide.py C:/qemu_test/ips_dev.txt
输出: runtime _text、slide, 以及"候选 × 热点 top12"供人工复核。
"""
import bisect, collections, io, os, re, sys
import numpy as np
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

HERE = os.path.dirname(os.path.abspath(__file__))
KS = os.path.join(HERE, 'kallsyms_g2a88cd145def.txt')
IMG = os.path.join(HERE, 'kernel_dev_g2a88cd145def.bin')
BASE = 0xffffffc010080000          # 链接期 _text
GAP = 0x2000000                    # 簇切分的间隙阈值(32MB)

def load_ips(path):
    out = set()
    for line in io.open(path, encoding='utf-8', errors='replace'):
        m = re.search(r'\b([0-9a-f]{16})\b', line)
        if m:
            v = int(m.group(1), 16)
            if v >> 48 == 0xffff:           # 只留内核态地址
                out.add(v)
    return sorted(out)

def load_syms(path):
    s = []
    for line in io.open(path, encoding='utf-8', errors='replace'):
        p = line.split()
        if len(p) >= 3 and re.fullmatch(r'[0-9a-f]{16}', p[0]):
            s.append((int(p[0], 16), p[1], ' '.join(p[2:])))
    s.sort()
    return s

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else r'C:/qemu_test/ips_dev_20260927.txt'
    syms = load_syms(KS)
    addrs = [a for a, _, _ in syms]
    def sa(name):
        for a, t, n in syms:
            if n == name: return a
        raise SystemExit('缺符号 ' + name)
    ET = sa('_etext'); TL = ET - BASE
    # 函数区间表(排除 .cfi_jt 这类数据表)
    funcs = []
    for i, (a, t, n) in enumerate(syms):
        if t in ('t', 'T') and not n.endswith('.cfi_jt'):
            e = addrs[i + 1] if i + 1 < len(addrs) else a + 4
            if BASE <= a < ET and e > a:
                funcs.append((a - BASE, e - BASE))
    funcs.sort()
    ia = np.array([f[0] for f in funcs]); ib = np.array([f[1] for f in funcs])
    name_at = {}
    for a, t, n in syms:
        name_at[a] = n
    sa_list = sorted(name_at)

    ips = load_ips(path)
    if not ips:
        raise SystemExit('没有样本: ' + path)
    # 主簇
    groups = []; cur = [ips[0]]
    for x in ips[1:]:
        if x - cur[-1] > GAP: groups.append(cur); cur = [x]
        else: cur.append(x)
    groups.append(cur)
    groups.sort(key=len, reverse=True)
    big = groups[0]
    print("样本 %d, 分组 %s" % (len(ips), [(len(g), hex(g[0]), hex(g[-1])) for g in groups[:4]]))
    print("主簇 %d 样本, 宽 %x; text_len=%x (%.1f MB)" % (len(big), big[-1] - big[0], TL, TL / 1048576))
    ipb = np.array(big, dtype=np.uint64)
    lo_c, hi_c = big[-1] - TL, big[0]
    T = (lo_c // 0x200000) * 0x200000 + (BASE % 0x200000)
    res = []
    while T <= hi_c + 0x200000:
        if T >= lo_c - 0x200000:
            o = ipb - np.uint64(T)
            ok = o < np.uint64(TL)
            good = 0
            if ok.any():
                sel = o[ok].astype(np.int64)
                j = np.clip(np.searchsorted(ia, sel, side='right') - 1, 0, len(ia) - 1)
                good = int(((sel >= ia[j]) & (sel < ib[j])).sum())
            cnt = collections.Counter()
            for ip in big:
                off = ip - T
                if 0 <= off < TL:
                    k = bisect.bisect_right(sa_list, BASE + off) - 1
                    if k >= 0:
                        cnt[name_at[sa_list[k]]] += 1
            res.append((good, T, cnt))
        T += 0x200000
    res.sort(key=lambda x: -x[0])
    print("\n候选 %d 个 (slide 以 2MB 为步长)" % len(res))
    for good, T, cnt in res:
        print("== T=_text_runtime=%x  slide=%+x  区间内 %d/%d ==" % (T, T - BASE, good, len(big)))
        print("   热点 top10: " + ", ".join("%s(%d)" % (k, v) for k, v in cnt.most_common(10)))
    print("""
判读: 选"热点全是 kfree/kmem_cache_*/avc_lookup/__d_lookup/__pi_memset/vsnprintf/
      __arm64_sys_* 这类真正常热路径"的那一档; 若最高的两档都很合理, 就再加样本重跑。""")

main()
