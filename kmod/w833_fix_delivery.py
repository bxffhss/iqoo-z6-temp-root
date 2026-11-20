# -*- coding: utf-8 -*-
"""修 DELIVERY.md 三件事：①删掉我刚才 Edit 造成的两段**重复段**(第 55/54 发各出现两次)；
②把登记值按真文件改对(w821 我抄了印象里的旧 md5)；③把"打包器/推送件默认"那句改现值。
两阶段：先全局核(每条锚必须恰好命中期望次数)，全绿才写；写完读回断言。"""
import io, os, sys, hashlib, re

P = "kmod/DELIVERY.md"
s = io.open(P, encoding="utf-8").read()
lines = s.split("\n")

# ---- 阶段一 ----
def count_prefix(pref):
    return sum(1 for l in lines if l.startswith(pref))

p55 = "**10-25 11:3x 第 55 发（§6.428，1 枪）新登记／改值的件**"
p54 = "**10-25 04:3x 第 54 发（§6.427，1 枪）新登记／改值的件**"
exp = [
    (count_prefix(p55), 2, "第 55 发那段现在必须是 2 份(我写的新版＋原来那份)，才谈得上删重"),
    (count_prefix(p54), 2, "第 54 发那段同上"),
    (s.count("`kmod/w821_birth_test3.py`＝`ffcf262c"), 1, "错的 w821 登记值应恰好 1 处"),
    (s.count("`kmod/kernelsu_rc74b.ko`＝`18750560…`(10-24 22:0x 起打包器与推送件默认都指它"), 1,
     "『打包器与推送件默认都指 rc74b』那句应恰好 1 处"),
    (s.count("回执 `ok kernelsu.ko 18750560…`(★10-24 22:0x 起默认＝**rc74b**"), 1,
     "第 17 行那句 push_ksu 回执应恰好 1 处"),
]
bad = [(a, b, w) for (a, b, w) in exp if a != b]
for a, b, w in exp:
    if a != b:
        print("[x] 现得 %s 期望 %s —— %s" % (a, b, w))
if bad:
    sys.exit(1)
print("[ok] 阶段一核过 %d 条" % len(exp))

# ---- 阶段二：删重复(保留每段**第二次**出现的那份=原文旧版？不：保留我重写的那份=第一次) ----
def drop_second(pref):
    global lines
    idx = [i for i, l in enumerate(lines) if l.startswith(pref)]
    keep, drop = idx[0], idx[1]
    assert keep < drop
    # 删掉 drop 那一行**以及它后面的空行**(保持段落间隔)
    del_idx = [drop]
    if drop + 1 < len(lines) and lines[drop + 1].strip() == "":
        del_idx.append(drop + 1)
    for i in sorted(del_idx, reverse=True):
        del lines[i]
    return keep, del_idx

a1 = drop_second(p55)
a2 = drop_second(p54)
s = "\n".join(lines)
print("  删重：第 55 发保留行 %d、删 %s；第 54 发保留行 %d、删 %s" % (a1[0] + 1, a1[1], a2[0] + 1, a2[1]))

# ---- 阶段二续：登记值改对 + 默认件那句改现值 ----
FIX = [
    ("`kmod/w821_birth_test3.py`＝`ffcf262c", "`kmod/w821_birth_test3.py`＝`144479b8"),
    ("`kmod/kernelsu_rc74b.ko`＝`18750560…`(10-24 22:0x 起打包器与推送件默认都指它",
     "`kmod/kernelsu_rc74b.ko`＝`18750560…`(10-24 22:0x 起打包器与推送件默认曾指它；★**10-25 第 57 发起两处默认都指 `kmod/kernelsu_rc74c.ko`＝`324eda4d…`**，但**认证过的那一份仍是 rc74b 包** ⇒ 默认≠已认证，见下面 57 发那段)"),
    ("回执 `ok kernelsu.ko 18750560…`(★10-24 22:0x 起默认＝**rc74b**，见 §6.422：**这是候选包**",
     "回执 `ok kernelsu.ko 324eda4d…`(★10-25 第 57 发起 `kmod/push_ksu.sh` 的默认＝**rc74c**；上一版默认 rc74b 的回执是 `18750560…`，见 §6.422：**这两支都还只是候选包**"),
]
for old, new in FIX:
    assert s.count(old) == 1, "写阶段锚 [%s…] 命中 %d" % (old[:24], s.count(old))
    s = s.replace(old, new, 1)
io.open(P, "w", encoding="utf-8", newline="").write(s)

# ---- 读回复证 ----
back = io.open(P, encoding="utf-8").read()
assert back.count(p55) == 1 and back.count(p54) == 1, "删重之后每段应各 1 份"
assert "ffcf262c" not in back, "错的 w821 值还在"
assert "`kmod/w821_birth_test3.py`＝`144479b8" in back
assert "两处默认都指 `kmod/kernelsu_rc74c.ko`" in back
# 登记的这几个 md5 必须与真文件一致(拿仓库当正对照)
for nm, claim in (("kmod/w820_add_birthfd3.py", "a694bfae"), ("kmod/w821_birth_test3.py", "144479b8"),
                  ("kmod/kernelsu_rc74c.ko", "324eda4d"), ("kmod/w413_selftest_sweep.sh", "727ec44d"),
                  ("z6root.zip", "880e9ef2")):
    act = hashlib.md5(io.open(nm, "rb").read()).hexdigest()
    assert act.startswith(claim), "%s 登记=%s 实际=%s" % (nm, claim, act[:8])
print("[ok] 读回通过：段落各 1 份；五个登记 md5 与真文件逐一相等；行数=%d md5=%s" % (
    back.count("\n"), hashlib.md5(back.encode("utf-8")).hexdigest()[:8]))
