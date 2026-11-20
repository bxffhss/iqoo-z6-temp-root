#!/usr/bin/env python3
"""w675_docsync2.py —— 把 w673 自己接进总闸的 py_compile 清单，再把"总闸换了版"这件事成对写回三份对外件。
   为什么单独一条脚本：w413 一改，凡登记它哈希的地方立刻全部滞后(例 160：闸没报红不等于验过)，
   而这次连"上一次登记的现值"也变成历史 ⇒ 一律现取，旧值去掉`名字＝哈希`的成对形状(去掉登记语义)。
"""
import hashlib
import io
import sys

W413 = "kmod/w413_selftest_sweep.sh"
s = io.open(W413, encoding="utf-8").read()
OLD = "kmod/w557_seed_abort_table.py kmod/w558_mk_rm3.py; do"
NEW = "kmod/w557_seed_abort_table.py kmod/w558_mk_rm3.py kmod/w673_docsync.py; do"
if "kmod/w673_docsync.py" in s:
    print("  [skip] w413 里已有 w673")
elif s.count(OLD) != 1:
    print("[x] w413 的 py 清单锚点命中 %d 次(应 1)⇒ 不改" % s.count(OLD))
    sys.exit(1)
else:
    io.open(W413, "w", encoding="utf-8", newline="\n").write(s.replace(OLD, NEW))
    print("  [OK] w413：w673_docsync.py 已接进 py_compile 清单")

cur = hashlib.md5(io.open(W413, "rb").read()).hexdigest()[:8]
print("  总闸现值=%s" % cur)

DOCS = ["kmod/DELIVERY.md", "analysis/CONTINUE_HERE.md", "analysis/CURRENT-STATUS.md"]
PAIR_OLD = "`kmod/w413_selftest_sweep.sh`＝`020daad0…`"     # 上一轮 docsync 写进去的"现值"，现在成历史
LINE50 = "`kmod/w413_selftest_sweep.sh`＝`daf3bdd1…`"        # DELIVERY 第 50 行那条(第 49 发登记的现值)
n = 0
for d in DOCS:
    t = io.open(d, encoding="utf-8").read()
    before = t
    t = t.replace(PAIR_OLD, "`kmod/w413_selftest_sweep.sh`＝`%s…`" % cur)
    if d == "kmod/DELIVERY.md":
        # 去成对：名字与 ＝ 之间插"当时" ⇒ 这条不再被当成当前登记(R9 只认 `名字`＝`哈希` 这种成对形状)
        t = t.replace(LINE50, "`kmod/w413_selftest_sweep.sh` 当时＝ `daf3bdd1…`")
    if t != before:
        io.open(d, "w", encoding="utf-8", newline="\n").write(t)
        n += 1
        print("  [OK] 写了 %s" % d)
print("=== w675 完成：改了 %d 份文档；总闸现值=%s ===" % (n, cur))
