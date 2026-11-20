#!/usr/bin/env python3
# w953b_rule_diff_probe.py — 语义差分的**权威口径**（前两版的读数都不能直接信，见下面两条 ★）。
#   ★坑一(第一版 w952b)：旗标写错(`sesearch -A -N -C`)⇒两侧都倒出**空文件**⇒"0 差异＝等价"是假的。
#   ★坑二(w953)：权限集解析写成"必须以 `{…}` 结尾"⇒ sesearch 默认输出是**不带大括号的空格串**，
#                 于是"厂商权限数=0"这种荒唐读数被打印出来（这次靠"荒唐"发现，不是靠断言——已补断言）。
#   ⇒ 这一版：①先报**解析覆盖率**（不 100% 就 exit 3，不比）；②按 (源,目标,类) **三元组**做双向差；
#     ③对两边都有的三元组比**权限集合**；④把"文本整行不同但集合相同"单独一档（＝secilc 合并/拆分串形）。
import re, sys
from collections import defaultdict

base = sys.argv[1] if len(sys.argv) > 1 else "/home/lucy/pol2"
TRI = re.compile(r"^allow\s+(\S+)\s+([\w-]+):([\w-]+)\s+(.*)$")


def load(path):
    d, bad, total = defaultdict(set), [], 0
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        total += 1
        m = TRI.match(line)
        if not m:
            bad.append(line)
            continue
        perms = m.group(4).strip().strip("{};").replace("}", "").split()
        d[(m.group(1), m.group(2), m.group(3))] |= {p.strip(";") for p in perms if p}
    return d, bad, total


v, vbad, vtot = load(f"{base}/vendor.allow.txt")
o, obad, otot = load(f"{base}/ours.allow.txt")
print("P0 行数：厂商=%d(解析失败 %d) 我们=%d(解析失败 %d)" % (vtot, len(vbad), otot, len(obad)))
if vbad:
    print("   厂商侧解析失败样例:", vbad[:2])
if obad:
    print("   我们侧解析失败样例:", obad[:2])
cov_v, cov_o = (vtot - len(vbad)) / max(vtot, 1), (otot - len(obad)) / max(otot, 1)
print("P1 解析覆盖率：厂商=%.4f 我们=%.4f" % (cov_v, cov_o))
if cov_v < 0.999 or cov_o < 0.999:
    print("PZ_END 覆盖率<99.9%% ⇒ 仪器不忠实，**不出结论**")
    sys.exit(3)

vk, ok = set(v), set(o)
gone, extra, both = vk - ok, ok - vk, vk & ok
lost_perm = sum(len(v[k]) for k in gone)
weaker = [(k, v[k] - o[k]) for k in both if v[k] - o[k]]
stronger = [(k, o[k] - v[k]) for k in both if o[k] - v[k]]
print("P2 三元组级双向差：")
print("   厂商有、我们完全没有      = %d 个三元组（带走 %d 个权限）" % (len(gone), lost_perm))
print("   我们有、厂商完全没有      = %d" % len(extra))
print("   两边都有、但我们权限更少  = %d 个三元组（合计少 %d 个权限）" % (len(weaker), sum(len(x[1]) for x in weaker)))
print("   两边都有、但我们权限更多  = %d 个三元组（合计多 %d 个权限）" % (len(stronger), sum(len(x[1]) for x in stronger)))
for k, ps in weaker[:6]:
    print("     少: %s %s:%s ← %s" % (k[0], k[1], k[2], " ".join(sorted(ps))[:60]))
for k, ps in stronger[:6]:
    print("     多: %s %s:%s → %s" % (k[0], k[1], k[2], " ".join(sorted(ps))[:60]))
print("P3 结论口径：装载一个 base 的**合格线**＝上面四个数里，`厂商有我们没有`=0 且 `两边都有但我们更少`=0；"
      "允许非零的只有\"我们多加的那几条\"（并且要逐条点名）。")
print("PZ_END date-ish; 厂商侧独有源前 10 个（找缺的输入面用）:")
from collections import Counter
print("   ", Counter(k[0] for k in gone).most_common(10))
print("   目标类前 10：", Counter(k[1] + ":" + k[2] for k in gone).most_common(10))
