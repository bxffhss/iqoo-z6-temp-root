#!/usr/bin/env python3
# w557_seed_abort_table.py —— 把所有拉回的 dmesg 件排成一张表：这发有几种"往触发口排队"、几种"zygote 收到 signal 6"，
#   再把每一个 abort 的 pid 回查是不是同一发里被排过队的 pid，并算"排队→abort"的延迟。
#   为什么要它：§6.394/6.395 的归因一直在"PMIC/试验台"和"我们自己的补装"之间摆；这张表把两边分开数。
import io
import re
import glob
import sys

SEED = "KSUFDINST 已排队给"
CALL = "KSUFDINST 回调跑在"
SKIP = "NULLFILES skip"
ABORT = re.compile(r"init: Service 'zygote' \(pid (\d+)\) received signal (\d+)")
TS = re.compile(r"^\s*<?\[?\s*([0-9]+)\.([0-9]+)\]?")


def ts(line):
    m = TS.match(line)
    return int(m.group(1)) if m else None


def tsf(line):
    m = TS.match(line)
    return float(m.group(1) + "." + m.group(2)) if m else None


def main():
    pats = sys.argv[1:] or ["kmod/w103_evidence/*dmesg*", "kmod/w103_evidence/*dmesg*.gz"]
    files = []
    for p in pats:
        files += [f for f in glob.glob(p) if not f.endswith(".py")]
    rows = []
    for f in sorted(set(files)):
        try:
            if f.endswith(".gz"):
                import gzip
                s = gzip.open(f, "rt", encoding="utf-8", errors="replace").read()
            else:
                s = io.open(f, encoding="utf-8", errors="replace").read()
        except Exception as e:
            print("[x] %s ⇒ %s" % (f, e))
            continue
        L = s.split("\n")
        seeds = [(tsf(l), int(re.search(r"pid=(\d+)", l).group(1))) for l in L
                 if SEED in l and re.search(r"pid=(\d+)", l)]
        calls = [ts(l) for l in L if CALL in l]
        skips = [ts(l) for l in L if SKIP in l]
        aborts = []
        for l in L:
            m = ABORT.search(l)
            if m:
                aborts.append((tsf(l), int(m.group(1)), int(m.group(2))))
        sp = set(p for _, p in seeds)
        matched = [(t, p, sig) for t, p, sig in aborts if p in sp]
        if not seeds and not aborts:
            continue
        rows.append((f, len(L), len(seeds), len(calls), len(skips), len(aborts), len(matched)))
        print("== %s 行数=%d 排队=%d 回调=%d skip=%d abort=%d 其中abort的pid曾被排队=%d"
              % (f, len(L), len(seeds), len(calls), len(skips), len(aborts), len(matched)))
        for t, p, sig in aborts:
            st = [q for q, pp in seeds if pp == p]
            tag = ("排队时刻=%s 延迟=%s" % (st[0], (t - st[0]) if (st and t is not None and st[0] is not None) else "?")) if st else "没被排过队"
            print("     abort up=%s pid=%d signal=%d  %s" % (t, p, sig, tag))
    print("\n-- 汇总：有排队或有 abort 的件数=%d --" % len(rows))
    tot = [0] * 6
    for r in rows:
        for i in range(1, 7):
            tot[i - 1] += r[i]
    print("   合计 行数=%d 排队=%d 回调=%d skip=%d abort=%d 配对abort=%d" % tuple(tot))
    return 0


if __name__ == "__main__":
    sys.exit(main())
