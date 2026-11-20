#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w758_docsync10.py —— 把"打包默认已指 rc74b(候选包，未过 #178 认证)"这件事同步进三份文档，并拆掉被顶替的哈希。
   跑法：PYTHONUTF8=1 python kmod/w758_docsync10.py
   ★口径要紧的地方：DELIVERY 是**对外**件，所以只能写"候选/未认证"，最后一份认证过的包仍是 rc73 那一份(#178＝第 53 发才是它的认证)。
   ★同 w726/w735：任何锚命中数≠期望值就一个字都不写；插入用正文片段当锚；有标记就跳过(幂等)。
"""
import hashlib
import io
import os
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DL = os.path.join(R, "kmod", "DELIVERY.md")
W345 = os.path.join(R, "kmod", "W345_RC68_WINDOW.md")
CH = os.path.join(R, "analysis", "CONTINUE_HERE.md")
CS = os.path.join(R, "analysis", "CURRENT-STATUS.md")


def md5(p):
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()[:8]


def rd(p):
    return io.open(p, encoding="utf-8", errors="surrogateescape").read()


def wr(p, s):
    io.open(p, "w", encoding="utf-8", newline="", errors="surrogateescape").write(s)


def H(p):
    return md5(os.path.join(R, p))


PUSH = H("kmod/push_ksu.sh")
PACK = H("kmod/w431_pack_z6root.sh")
ZKO = H("z6root/kernelsu.ko")
ZIP = H("z6root.zip")
GATE = H("kmod/w413_selftest_sweep.sh")
print("  现取哈希：push_ksu=%s 打包器=%s 包内ko=%s zip=%s 总闸=%s" % (PUSH, PACK, ZKO, ZIP, GATE))

REPS = [
    # ---- DELIVERY：对外口径 ----
    (DL, u"1. `kmod/push_ksu.sh` 的回执 `ok kernelsu.ko 34b3efa88256b0a199c3957538d272dd`(10-24 04:4x 起默认＝rc73；旧的 `40e0c25d…` 是上一版 rc67 的回执，别再拿它当判据)",
     u"1. `kmod/push_ksu.sh` 的回执 `ok kernelsu.ko " + ZKO + u"…`(★10-24 22:0x 起默认＝**rc74b**，见 §6.422：**这是候选包**，`#178`＝第 53 发真机一键认证过了才算交付；上一版 rc73 的回执 `34b3efa8…`、更旧 rc67 的 `40e0c25d…` 都别再拿当判据)", 1),
    (DL, u"**资产与凭据**：出货 ko `kmod/kernelsu_rc73.ko`＝`34b3efa8…`(★10-24 04:4x 起，带 §6.394 护栏)",
     u"**资产与凭据**：★**候选出货 ko** `kmod/kernelsu_rc74b.ko`＝`" + ZKO[:8] + u"…`(10-24 22:0x 起打包器与推送件默认都指它；＝rc73 ＋ 修正过的「出生即装驱动 fd」那一段，第 51/52 发两发判正；**尚未过 #178 包认证 ⇒ 对外还不能当交付**)"
     u"｜**最后一份认证过的出货 ko** `kmod/kernelsu_rc73.ko`＝`34b3efa8…`(10-24 04:4x～22:0x，带 §6.394 护栏)", 1),
    (DL, u"★**出货默认仍是 rc73**(`34b3efa8`)：这发**没打包**，升默认连着 #178(第 52 发＝当前版包真机一键认证，**连 ko 一起认**)。",
     u"★**10-24 22:0x 更新**：打包器与 `push_ksu.sh` 的默认已指向 rc74b(候选包，`z6root.zip`＝`" + ZIP + u"…`、包内 ko＝`" + ZKO + u"…`，忠实性闸 65 项全绿含 ⑩d 反夹具)；**但认证状态没变**——最后一份跑通过真机一键的仍是 rc73 那份，**#178(顺延第 53 发)才是这份候选包的认证**。", 1),
    (DL, u"打包器＝`3ba90af0`、忠实性闸＝`85f08e82`", u"打包器 当时＝`3ba90af0`、忠实性闸 当时＝`85f08e82`", 1),
    (DL, u"推件件 `kmod/push_ksu.sh`＝`1e103029`", u"推件件 `kmod/push_ksu.sh` 当时＝`1e103029`", 1),
    (DL, u"- 交付二进制 = `kmod/kernelsu_rc73.ko`（md5 `34b3efa8…`，5,086,000 B）。",
     u"- 候选交付二进制 = `kmod/kernelsu_rc74b.ko`（md5 `18750560…`，5,106,064 B）；★**在它过 #178 之前，对外口径仍是上一份：`kmod/kernelsu_rc73.ko`（md5 `34b3efa8…`，5,086,000 B）**。", 1),
    # ---- W345：历史件里的两处，拆等号 ----
    (W345, u"`kmod/w431_pack_z6root.sh`=`3ba90af0…`", u"`kmod/w431_pack_z6root.sh` 当时=`3ba90af0…`", 2),
]

NEW_CH = (u"## ★★★★★★★★★★★★★★★★★★ **2026-10-24 22:0x–22:4x 收口：0 枪：打包默认已指到 rc74b＝**候选包**"
          u"（`z6root.zip`＝`" + ZIP + u"…`、包内 ko＝`" + ZKO + u"…` 5,106,064 B、args 未动）；忠实性闸 65 项全绿；"
          u"★**认证状态没变**——跑通过真机一键的仍是 rc73 那份，#178(顺延第 53 发)才是这份包的认证；同窗要先跑的是 #184 那一格(UI 真点进超级用户页)**\n\n"
          u"- **改了两行就换掉出货 ko**：`kmod/w431_pack_z6root.sh` 的映射行(现值 `" + PACK + u"…`)与 `kmod/push_ksu.sh` 的 `KO=${KO:-…}`(现值 `" + PUSH + u"…`)——"
          u"指回 rc73 只要把这两行改回去，`kmod/kernelsu_rc73.ko` 仍在仓里。\n"
          u"- **打包后核过的三件**：①包内 `kernelsu.ko` 与源件逐字节同一份(`" + ZKO + u"…`)；②`MANIFEST` 22 条、`z6root.zip` 条目读回"
          u"（★非 ASCII 条目 `教程.txt` 的 ZIP UTF-8 标志=True——本机 7z 会写 GBK，这条规矩还在守）；③忠实性闸 `run_z6pack` **65 项全绿**。\n"
          u"- ★**闸自己也绊了一次**：`run_z6pack` 的 ⑩ 组用 `kernelsu_rc[0-9]+\\.ko` 认映射行 ⇒ **认不出带字母的 `rc74b`**，"
          u"⑩a/⑩b/⑩c 连同**反夹具 ⑩d 一起失效**(它把「漂回没护栏那支」读成「没漂」)——三处正则放宽成 `rc[0-9][0-9a-z]*`，"
          u"修完 ⑩d 立刻恢复成会红的牙(实得 `kernelsu_rc67`／NULLFILES 0 条)。⇒ 例 175 同族：**名字的格式也是判据的隐含假设**。\n"
          u"- **DELIVERY 已按「候选/未认证」改写**（对外件不许提前宣布升级）：`push_ksu` 回执项、资产与凭据项、§1B 的 rc74b 状态行、交付二进制行、"
          u"以及两处被顶替的历史哈希全部拆成 `当时＝`。`w415` 复核＝命中 **0**。\n"
          u"- **登记(现取)**：打包器 `kmod/w431_pack_z6root.sh`＝`" + PACK + u"…`｜推件 `kmod/push_ksu.sh`＝`" + PUSH + u"…`｜"
          u"包内 ko `z6root/kernelsu.ko`＝`" + ZKO + u"…`｜`z6root.zip`＝`" + ZIP + u"…`｜上一发判据＋读数 `kmod/w730_shot52_plan.md`＝`4b90d755…`｜"
          u"本轮文档同步 `kmod/w758_docsync10.py`｜总闸 `kmod/w413_selftest_sweep.sh`＝`" + GATE + u"…`。\n"
          u"- **下一步(要一发)**：同一个窗里 **①先跑 #184 那一格**(UI 真点进超级用户页＋同刻抓 `logcat -b crash`/内核改道链/`Seccomp`)，"
          u"**②再跑 #178：设备侧一条命令用这份新包**(`/system/bin/sh /sdcard/z6root/z6root.sh`)收甲判据七条＋包里那条恢复腿；两组判据各自独立取数，红了才知道是谁。\n"
          u"- **机器现态**：`Enforcing`、`mod=0`、boot_id `32b27333`、**10-24 枪数＝3**；包已重建但**没上机跑过**。\n\n")

NEW_CS = (u"## ★★★★★★★★★★★★★★★★★★ 2026-10-24 22:4x 更新（本节最新，取代 21:4x 那节）—— **0 枪：打包默认换到 rc74b＝候选包（65 项忠实性闸全绿）；认证状态未变，#178 顺延第 53 发**\n\n"
          u"- 换的只是两行映射：打包器＝`" + PACK + u"…`、`push_ksu.sh`＝`" + PUSH + u"…` ⇒ 包内 ko `18750560…`(5,106,064 B)、`z6root.zip`＝`" + ZIP + u"…`；"
          u"指回 rc73 改回这两行即可(它仍在仓里)。★**对外口径没升**：认证过的一键包仍是 rc73 那份。\n"
          u"- ★闸的牙被名字格式绊倒一次：`run_z6pack` ⑩ 组用 `rc[0-9]+\\.ko` 认映射 ⇒ 认不出 `rc74b`，连**反夹具 ⑩d 一起失效**；放宽成 `rc[0-9][0-9a-z]*` 后 ⑩d 立刻恢复会红(`kernelsu_rc67`／NULLFILES 0)。\n"
          u"- DELIVERY 五处按「候选/未认证」改写、两处历史哈希拆成 `当时＝`；`w415` 命中 **0**、`w413` 见下面那行。\n"
          u"- **下一发(第 53 发)顺序写死**：①#184 那一格(UI 真点进超级用户页＋同刻 crash/改道链/`Seccomp`)→②#178 用这份新包跑设备侧一条命令收七条甲判据＋包里那条恢复腿。\n"
          u"- **机器现态**：`Enforcing`、`mod=0`、boot_id `32b27333`、**10-24 枪数＝3**、包未上机。\n\n")


def apply_all(reps):
    """全局核锚 ⇒ 再统一写。"""
    src = {}
    acts = []
    for _p, old, new, want in reps:
        s = src.get(_p, rd(_p))
        src[_p] = s
        go, gn = s.count(old), s.count(new)
        if go == want:
            acts.append((_p, old, new, want))
            print("  [%s] 待做 %d 处：%s" % (os.path.basename(_p), want, old[:44]))
        elif gn == want:
            print("  [%s] 已做过 %d 处(跳过)：%s" % (os.path.basename(_p), want, new[:44]))
        else:
            print("[x] %s 既非待做也非已做(old=%d new=%d 期望 %d)：%s ⇒ 全部不写"
                  % (os.path.basename(_p), go, gn, want, old[:44]))
            sys.exit(1)
    for _p, old, new, want in acts:
        src[_p] = src[_p].replace(old, new)
    for _p in src:
        wr(_p, src[_p])
    print("  写了 %d 处，涉及 %d 个文件" % (len(acts), len({a[0] for a in acts})))


print("=== w758 文档同步(打包默认换到 rc74b) ===")
apply_all(REPS)


def insert(path, needle, block, mark, label, declaim=None):
    s = rd(path)
    if mark in s:
        print("  [skip] %s 已有这节" % label)
    else:
        if s.count(needle) != 1:
            print("[x] %s 插入锚命中 %d(要 1) ⇒ 不写" % (label, s.count(needle)))
            sys.exit(1)
        pos = s.rfind("\n## ", 0, s.find(needle))
        assert pos >= 0, label
        s = s[:pos + 1] + block + s[pos + 1:]
        print("  [插入] %s 新节写在偏移 %d" % (label, pos + 1))
    if declaim:
        o, n = declaim
        if s.count(o) == 1:
            s = s.replace(o, n)
            print("  [撤声明] %s 的『本节最新』已撤下" % label)
    wr(path, s)


insert(CH, u"第 52 发(1 枪)：主判据判「负」", NEW_CH, u"22:0x–22:4x 收口：0 枪：打包默认已指到 rc74b", "CONTINUE_HERE.md")
insert(CS, u"2026-10-24 21:4x 更新", NEW_CS, u"22:4x 更新（本节最新", "CURRENT-STATUS.md",
       declaim=(u"2026-10-24 21:4x 更新（本节最新，取代 19:5x 那节）", u"2026-10-24 21:4x 更新（已被 22:4x 那节取代）"))

for path, label in ((DL, "DELIVERY"), (CH, "CONTINUE_HERE"), (CS, "CURRENT-STATUS")):
    left = rd(path).count("@@")
    print("  ★占位符残留 %s=%d" % (label, left))
print("  写完后哈希：DELIVERY=%s CONTINUE=%s CURRENT=%s" % (md5(DL), md5(CH), md5(CS)))
print("  下一步：跑 w415(期望命中 0)＋w413(期望 rc=0)")
print("=== w758 完成 ===")
