"""sym_resolve —— 拿 /proc/kallsyms 的 dump + 一组裸地址，算出"地址落在哪个函数、偏移多少"。

为什么需要它：ftrace 的 options/stacktrace 用 %pS 解析，KCFI 的跳转表让 return address
落在 `__cfi_check` 那个巨型符号区间里 ⇒ 名字查不出来。kprobe 事件里抓的 `%x30`(LR) 是硬数值，
配上**同一次开机**的 kallsyms 就能精确算出调用者。

用法:
    python kmod/sym_resolve.py <kallsyms.txt> <hex地址> [hex地址...]
    python kmod/sym_resolve.py kmod/app_wXX/ksu_kallsyms.txt 0xffffffabc123
"""
import io
import re
import sys


def load(path):
    syms = []
    pat = re.compile(r"^([0-9a-fA-F]{8,16})\s+([tTdBdRrGiIaA])\s+(\S+)")
    with io.open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = pat.match(line)
            if m:
                syms.append((int(m.group(1), 16), m.group(2), m.group(3)))
    syms.sort()
    return syms


def resolve(syms, addr):
    lo, hi = 0, len(syms) - 1
    best = None
    while lo <= hi:
        mid = (lo + hi) // 2
        if syms[mid][0] <= addr:
            best = mid
            lo = mid + 1
        else:
            hi = mid - 1
    if best is None:
        return "0x%x: 比所有符号都小(地址 0?)" % addr
    a, t, n = syms[best]
    nxt = syms[best + 1][0] if best + 1 < len(syms) else None
    span = "" if nxt is None else "  (到下个符号 %+d)" % (nxt - addr - 1)
    return "0x%x -> %s%s [%c] +0x%x%s" % (addr, n, "", t, addr - a, span)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    S = load(sys.argv[1])
    print("kallsyms 符号数=%d" % len(S))
    if S and S[0][0] == 0 and all(x[0] == 0 for x in S[:20]):
        print("!! 前 20 个地址全是 0 ⇒ kptr_restrict 把地址抹了，这份 kallsyms 不能用")
    for a in sys.argv[2:]:
        print(resolve(S, int(a, 16)))
