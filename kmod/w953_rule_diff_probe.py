#!/usr/bin/env python3
# w953_rule_diff_probe.py — 把"只在某一侧的规则"回查成**同一 (源,目标,类) 三元组**两侧的权限集，
#   用来分清两件事：①真的少/多了规则 ②只是 secilc 把 `{a b c}` 合并或拆开的**串形不同**（同形不同串）。
#   ★为什么要这一步：`comm` 比的是整行文本；把"文本不等"直接读成"语义不等"＝例 185②（md5 对重新序列化的东西没判别力）的同族。
import sys, re
from collections import defaultdict

base = sys.argv[1] if len(sys.argv) > 1 else "/home/lucy/pol2"
vendor = open(f"{base}/vendor.allow.txt", encoding="utf-8", errors="replace").read().splitlines()
ours = open(f"{base}/ours.allow.txt", encoding="utf-8", errors="replace").read().splitlines()
only_ours = open(f"{base}/only_ours.txt", encoding="utf-8", errors="replace").read().splitlines()


def key(line):
    # "allow src tgt:class perms"  →  (src, tgt, class)
    m = re.match(r"^allow\s+(\S+)\s+(\S+?):(\S+)\s+(.*)$", line.strip())
    return (m.group(1), m.group(2), m.group(3)) if m else None


def perms(line):
    m = re.match(r"^allow\s+\S+\s+\S+?\s+(\{.*\}|\S+)\s*$", line.strip())
    if not m:
        return set()
    t = m.group(1).strip("{}")
    return set(t.split())


vmap, omap = defaultdict(set), defaultdict(set)
for l in vendor:
    k = key(l)
    if k:
        vmap[k] |= perms(l)
for l in ours:
    k = key(l)
    if k:
        omap[k] |= perms(l)

same_shape = missing_truly = only_ours_new = 0
print("回查『只在我们这侧』的每一条：")
for l in only_ours:
    k = key(l)
    if not k:
        print("  [跳过] 解析不了:", l[:80])
        continue
    p = perms(l)
    inv = vmap.get(k)
    if inv is None:
        only_ours_new += 1
        print("  ★真·新增（厂商件里这个三元组根本没有）: %s %s:%s  %s" % (k[0], k[1], k[2], " ".join(sorted(p))[:70]))
    elif p <= inv:
        same_shape += 1
        print("  ○串形不同（厂商侧同三元已含这些权限，只是没并成一串）: %s %s:%s  厂商=%d 我们=%d"
              % (k[0], k[1], k[2], len(inv), len(p)))
    else:
        missing_truly += 1
        print("  ▲同三元但权限不同: %s %s:%s  差=%s" % (k[0], k[1], k[2], " ".join(sorted(p - inv))[:70]))

# 反向：厂商侧有、我们侧整块缺失的三元组（这才是"少了规则"的硬指标）
vkeys, okeys = set(vmap), set(omap)
gone = vkeys - okeys
extra = okeys - vkeys
print("\n按三元组(不是按整行)算：")
print("  厂商有、我们**完全没有**的三元组 = %d" % len(gone))
print("  我们有、厂商**完全没有**的三元组 = %d" % len(extra))
perm_lost = sum(len(vmap[k]) for k in gone)
shrink = [(k, len(vmap[k] - omap[k])) for k in (vkeys & okeys) if vmap[k] - omap[k]]
print("  完全缺失三元组里带走的权限条数 = %d" % perm_lost)
print("  两边都有但**我们少了权限**的三元组数 = %d（合计少 %d 个权限）"
      % (len(shrink), sum(n for _, n in shrink)))
print("  小结：只在我们这侧的 %d 条里 → 串形不同 %d、真新增 %d、同三元权限不同 %d"
      % (len(only_ours), same_shape, only_ours_new, missing_truly))
print("\n样例（厂商有、我们没有的前 8 个三元组）:")
for k in sorted(gone)[:8]:
    print("   ", k[0], k[1] + ":" + k[2], "厂商权限数=%d" % len(vmap[k]))
