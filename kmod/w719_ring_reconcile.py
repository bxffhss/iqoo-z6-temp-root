#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w719 —— 离线吃 dmesg.live，把 rc74b 的逐 pid 证人算干净(判据③/④/⑥/⑧)。
   跑法：PYTHONUTF8=1 python kmod/w719_ring_reconcile.py kmod/w103_evidence/w717_dmesg_live_shot51.log
   ★规矩(§6.414 仪器教训)：
     · 半行(dd 把行切半)只当"存在这行"，**不许取里面的字段值** ⇒ 字段只在行首/行中有完整终止符时才解析。
     · 先打印覆盖区间(HB 心跳 + 内容最大时刻)，再报计数；覆盖不到就判"未测"。
     · 计数=0 时先问"这份件里同类高频行在不在"，不然说不出是 0。
"""
import collections
import io
import re
import sys

P = sys.argv[1] if len(sys.argv) > 1 else "kmod/w103_evidence/w717_dmesg_live_shot51.log"
raw = io.open(P, "rb").read()
print("=== w719 输入证人 %s 字节=%d ===" % (P, len(raw)))
# 这个跟随件是 dd 一段段追加的，行会被切半、HB 标记会插在行中 ⇒ 先按 \n 切，再单独数 HB。
lines = raw.split(b"\n")
print("  行数(按 \\n 切)=%d" % len(lines))

hb = []
for ln in lines:
    m = re.search(rb"HB up=([0-9.]+)", ln)
    if m:
        hb.append(float(m.group(1)))
print("  HB 心跳条数=%d  覆盖首=%s 末=%s" % (len(hb), hb[0] if hb else "-", hb[-1] if hb else "-"))

ts = []
for ln in lines:
    m = re.match(rb"\[\s*([0-9]+)\.[0-9]+\]", ln)
    if m:
        ts.append(int(m.group(1)))
print("  内容时间戳：最小 up=%s 最大 up=%s 带戳行数=%d" % (min(ts) if ts else "-", max(ts) if ts else "-", len(ts)))

# ---- 逐类计数：这些词元的**存在性**用整行正则(半行也算存在)，字段值只从完整行取 ----
PAT = {
    "seen Manager": rb"KSUBIRTH seen Manager",
    "queued self fd": rb"KSUBIRTH queued self fd",
    "kzalloc failed": rb"KSUBIRTH kzalloc\(ATOMIC\) failed",
    "task_work_add rc": rb"KSUBIRTH task_work_add",
    "dupskip": rb"KSUBIRTH dupskip",
    "childskip": rb"KSUBIRTH childskip",
    "cap": rb"KSUBIRTH cap",
    "=> fd=": rb"KSUFDINST .*=> fd=",
    "NULLFILES skip": rb"NULLFILES skip",
}
for k, v in PAT.items():
    n = sum(1 for ln in lines if re.search(v, ln))
    print("  存在性 %-16s = %d" % (k, n))

# ---- 逐 pid：queued 与 seen，字段必须完整(pid=数字 且后面还有空格，不是被切的尾巴) ----
def field(ln, key):
    m = re.search(key + rb"=(\d+)(?=\s|\[|$)", ln)
    return int(m.group(1)) if m else None

q = collections.Counter()
s = collections.Counter()
qs = {}
for ln in lines:
    if b"KSUBIRTH queued self fd" in ln:
        pid = field(ln, rb"pid")
        if pid is not None:
            q[pid] += 1
            cm = re.search(rb"comm=\[([^\]]*)\]", ln)
            if cm:
                qs[pid] = cm.group(1).decode("utf-8", "replace")
            t = field(ln, rb"total")
            if t is not None:
                qs.setdefault(pid, "")
                qs[pid] += "|total=%d" % t
    if b"KSUBIRTH seen Manager" in ln:
        pid = field(ln, rb"pid")
        if pid is not None:
            s[pid] += 1

print("  --- ③ 去重正证：queued self fd 逐 pid(字段完整的行) ---")
for pid, n in sorted(q.items(), key=lambda kv: -kv[1]):
    print("    pid=%-7s queued=%d  %s" % (pid, n, qs.get(pid, "")))
print("    合计 queued 行(带完整 pid 字段)=%d  不同 pid=%d  最大单 pid 次数=%d"
      % (sum(q.values()), len(q), max(q.values()) if q else 0))
print("    ★判据③口径：每个 pid 恰好 1 ⇒ 上面若有 >1 就是去重没生效")

print("  --- ⑥ 谓词收窄：被排队的 pid 都是谁(comm) ---")
for pid, n in sorted(q.items()):
    print("    pid=%-7s comm=[%s]" % (pid, qs.get(pid, "?")))

print("  --- seen Manager 逐 pid(应 ≥ 每个 queued pid 一条) ---")
for pid, n in sorted(s.items()):
    print("    pid=%-7s seen=%d" % (pid, n))
print("    seen 合计=%d  queued 合计=%d  差=%d(>0 ⇒ 有的 seen 后面没 queued 或被半行吞了)"
      % (sum(s.values()), sum(q.values()), sum(s.values()) - sum(q.values())))

print("  --- ④ 挡住的分支：dupskip / childskip 的最大 n 与涉及 pid ---")
for name in ("dupskip", "childskip"):
    ns, ps = [], collections.Counter()
    for ln in lines:
        if ("KSUBIRTH %s" % name).encode() in ln:
            n = field(ln, rb"n")
            pid = field(ln, rb"pid")
            if n is not None:
                ns.append(n)
            if pid is not None:
                ps[pid] += 1
    print("    %-9s 行数=%d 最大 n=%s 完整字段行=%d 涉及 pid=%s"
          % (name, sum(1 for ln in lines if ("KSUBIRTH %s" % name).encode() in ln),
             max(ns) if ns else "-", len(ns), dict(ps.most_common(8))))

print("  --- ⑤ 回调跑在(=> fd=)逐 pid，用来对『排队⇒回调』同数 ---")
f = collections.Counter()
for ln in lines:
    if b"=> fd=" in ln:
        pid = field(ln, rb"pid")
        fd = field(ln, rb"fd")
        if pid is not None:
            f[pid] += 1
            if fd is not None:
                print("    pid=%-7s fd=%s" % (pid, fd))
print("    合计=%d 不同 pid=%d" % (sum(f.values()), len(f)))
print("  --- ⑧ 稳定性 ---")
for name, pat in (("kzalloc failed", rb"KSUBIRTH kzalloc\(ATOMIC\) failed"),
                  ("task_work_add", rb"KSUBIRTH task_work_add"),
                  ("cap total", rb"KSUBIRTH cap"),
                  ("NULLFILES skip", rb"NULLFILES skip"),
                  ("signal 6", rb"received signal 6")):
    print("    %-16s = %d" % (name, sum(1 for ln in lines if re.search(pat, ln))))
print("=== w719 DONE ===")
