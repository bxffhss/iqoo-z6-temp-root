import io, re, sys

# w787_live_analyze.py —— 离线读一份 `dmesg.live` 跟随件的产物，算「覆盖区间 + KSUBIRTH 各分支计数 + 预算现值」。
#   ★例 176③ 第二次兑现写进代码里：`dmesg.live` 的行首是 `<6>` 级别前缀，**时间戳必须在行内搜**；
#     用行锚定的 `^\[` 会把 6 万行只数出 1873 行"带时刻"，覆盖区间读窄一半、`total=`/`n=` 最大值直接读成 None(假否据)。
#   ★两条规矩：①被切半的续行只准用于**存在性**计数，不准取字段值；②计数=0 只在这份文件自己证明"覆盖到了那一刻"时才是否据。
P = sys.argv[1] if len(sys.argv) > 1 else r"kmod/w103_evidence/shot54/w787_live.snap"
raw = io.open(P, "rb").read()
lines = raw.decode("utf-8", "replace").split("\n")
print("=== W787 离线分析：%s (%d 字节) ===" % (P, len(raw)))
print("  总行数=%d  末行是否空=%s" % (len(lines), lines[-1] == ""))


def ts(l):
    m = re.search(r"\[\s*([0-9]+)\.[0-9]+\]", l)
    return float(m.group(1)) if m else None


def full(l):
    return re.search(r"\[\s*[0-9]+\.[0-9]+\]", l) is not None


st = [ts(l) for l in lines if ts(l) is not None]
print("  带时间戳行=%d  覆盖 up=%s → %s (跨 %s 秒)"
      % (len(st), st[0] if st else "无", st[-1] if st else "无",
         ("%.1f" % (st[-1] - st[0])) if len(st) > 1 else "无"))
if len(st) < len([l for l in lines if l.strip()]) * 0.5:
    print("  [BAD] 带时刻的行不到一半 ⇒ 时间戳的正则又写成行锚定了(例 176③)")
    sys.exit(1)
half = sum(1 for l in lines if l.strip() and not full(l))
print("  不含时间戳的行(=被切半的续行)=%d ⇒ 只准用于存在性，不准取字段值" % half)

kb = [l for l in lines if "KSUBIRTH" in l]
print("  KSUBIRTH 行数=%d  其中带时刻=%d" % (len(kb), sum(1 for l in kb if full(l))))
q = [l for l in kb if "queued self fd" in l]
cap = [l for l in kb if "KSUBIRTH cap" in l]
dup = [l for l in kb if "dupskip n=" in l]
chld = [l for l in kb if "childskip" in l]
seen = [l for l in kb if "seen Manager" in l]
print("  queued self fd=%d  cap=%d  dupskip=%d  childskip=%d  seen Manager=%d  合计=%d"
      % (len(q), len(cap), len(dup), len(chld), len(seen),
         len(q) + len(cap) + len(dup) + len(chld) + len(seen)))


def maxint(ls, key):
    vals = []
    for l in ls:
        if not full(l):
            continue
        m = re.search(key + r"=([0-9]+)", l)
        if m:
            vals.append(int(m.group(1)))
    return (max(vals), len(vals)) if vals else (None, 0)


t = maxint(q, "total")
d = maxint(dup, "n")
print("  total 最大值=%s(完整行 %d 条)   dupskip n 最大值=%s(完整行 %d 条)" % (t[0], t[1], d[0], d[1]))
for l in (q[:1] + q[-1:]):
    print("  queued: %s" % l[:170])
for l in cap[:4]:
    print("  cap 行: %s" % l[:170])

buckets = {}
for l in kb:
    v = ts(l)
    if v is None:
        continue
    k = int(v // 300) * 300
    buckets[k] = buckets.get(k, 0) + 1
print("  每 300 秒的 KSUBIRTH 行数：%s" % (" ".join("up%d-%d:%d" % (k, k + 300, buckets[k]) for k in sorted(buckets)) or "无"))

su = [l for l in lines if "KSUBEAT" in l]
print("  KSUBEAT 行数=%d  SU0=%d SU1=%d SD4=%d"
      % (len(su), sum(1 for l in su if "SU0" in l), sum(1 for l in su if "SU1" in l),
         sum(1 for l in su if "SD4" in l)))
sig = [l for l in lines if "received signal 6" in l]
sys_ = [l for l in lines if "SIGSYS" in l or "syscall 142" in l]
print("  received signal 6=%d  SIGSYS/syscall142 行=%d" % (len(sig), len(sys_)))
print("  ★★这份文件的停笔时刻=%s ⇒ 之后一切『计数=0』都只是「这段没覆盖」，不是「没发生」"
      % (("%.0f" % st[-1]) if st else "无"))
print("=== 完 ===")
