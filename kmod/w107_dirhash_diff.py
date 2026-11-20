#!/usr/bin/env python3
# w107_dirhash_diff.py —— 把 w106 在两台出的逐件哈希表当集合比，并且**先自证两侧非空、
#   再把解析不掉的行原样数出来**(例 187/195：把"我没解析到"读成"那边没有"是最坏的一种假结论)。
# 跑法：PYTHONUTF8=1 python kmod/w107_dirhash_diff.py
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OLD = ROOT / "kmod" / "w103_evidence" / "dirhash_old.txt"
NEW = ROOT / "kmod" / "w103_evidence" / "dirhash_new.txt"
LINE = re.compile(r'^([0-9a-f]{32}) +(.+)$')


def load(p):
    m = {}
    junk = []
    n = 0
    for raw in p.read_text(encoding='utf-8', errors='replace').splitlines():
        if not raw.strip():
            continue
        n += 1
        mm = LINE.match(raw)
        if mm:
            m[mm.group(2)] = mm.group(1)
        else:
            junk.append(raw)
    return m, junk, n


a, ja, na = load(OLD)
b, jb, nb = load(NEW)
print('旧机 物理行=%d 入账=%d 解析不掉=%d' % (na, len(a), len(ja)))
print('新机 物理行=%d 入账=%d 解析不掉=%d' % (nb, len(b), len(jb)))
for tag, rows in (('旧', ja), ('新', jb)):
    for r in rows[:12]:
        print('  [%s 未入账行] %s' % (tag, r[:120]))
    if len(rows) > 12:
        print('  [%s 未入账行] …还有 %d 条' % (tag, len(rows) - 12))

# ★非空自证：两侧都必须真的数到东西，否则"0 差异"是假的
if len(a) < 3000 or len(b) < 3000:
    print('[x] 有一侧入账行数异常少(旧=%d 新=%d) ⇒ 清点件没跑成，本次结论作废' % (len(a), len(b)))
    sys.exit(3)

only_a = sorted(set(a) - set(b))
only_b = sorted(set(b) - set(a))
diff = sorted(p for p in set(a) & set(b) if a[p] != b[p])
print('\n== 名字集合 ==')
print('只在旧机(⇒新机没有)=%d  只在新机=%d  同名但哈希不同=%d' % (len(only_a), len(only_b), len(diff)))
for p_ in only_a[:60]:
    print('  [旧独有] %s' % p_)
if len(only_a) > 60:
    print('  …还有 %d 条' % (len(only_a) - 60))
for p_ in only_b[:40]:
    print('  [新独有] %s' % p_)
if len(only_b) > 40:
    print('  …还有 %d 条' % (len(only_b) - 40))
for p_ in diff[:40]:
    print('  [哈希不同] %s 旧=%s 新=%s' % (p_, a[p_][:8], b[p_][:8]))

print('\n== 按目录聚合"旧独有"，看它是哪一层 ==')
agg = {}
for p_ in only_a:
    parts = p_.split('/')
    agg['/'.join(parts[3:5]) if p_.startswith('/home/lucy/') else '/'.join(parts[:4])] = \
        agg.get('/'.join(parts[3:5]) if p_.startswith('/home/lucy/') else '/'.join(parts[:4]), 0) + 1
for k, v in sorted(agg.items(), key=lambda x: -x[1]):
    print('  %-50s %d 件' % (k, v))

# ★正对照：改坏一条必须立刻多一个差
probe = sorted(set(a) & set(b))[0]
mut = dict(b)
mut[probe] = '0' * 32
hit = [p_ for p_ in set(a) & set(mut) if a[p_] != mut[p_]]
want = len(diff) + (0 if probe in diff else 1)   # probe 已在差集里则差异数不变，但仍须"被这条尺判为不同"
print('\n正对照：把 %s 的哈希改坏 ⇒ 差异数 %d→%d(期望 %d)' % (probe, len(diff), len(hit), want))
if len(hit) != want or probe not in hit:
    print('[x] 正对照没生效 ⇒ 这把尺没牙')
    sys.exit(3)
print('[OK] 尺有牙')
