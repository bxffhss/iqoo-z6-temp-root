#!/usr/bin/env python3
"""w680_docsync3.py —— 出货 ko 从 rc67 换成 rc73 之后，把这件事**成对**写回四份对外件。
   规矩(例 160/171)：新值一律本脚本现算 md5；旧值降历史必须**拆掉 `名字`＝`哈希` 的成对形状**(R9 只认成对)；
   锚点命中数不为 1 就一个文件都不写。跑完必须重跑 w415 与 w413 看它们各自清零。
"""
import hashlib
import io
import sys

LIVE = {}


def md5(p):
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()


# ---------- 1) 先把自己接进总闸的 py_compile 清单，再算总闸现值 ----------
W413 = "kmod/w413_selftest_sweep.sh"
s = io.open(W413, encoding="utf-8").read()
ANCH = "kmod/w673_docsync.py kmod/w675_docsync2.py; do"
NEWA = "kmod/w673_docsync.py kmod/w675_docsync2.py kmod/w680_docsync3.py; do"
if "kmod/w680_docsync3.py" in s:
    print("  [skip] w413 里已有 w680")
elif s.count(ANCH) != 1:
    print("[x] w413 锚点命中 %d(应 1)⇒ 停" % s.count(ANCH))
    sys.exit(1)
else:
    io.open(W413, "w", encoding="utf-8", newline="\n").write(s.replace(ANCH, NEWA))
    print("  [OK] w413：w680 已接进 py_compile 清单")

for p in ["kmod/kernelsu_rc73.ko", "kmod/push_ksu.sh", "kmod/w431_pack_z6root.sh",
          "kmod/_tmp_selftest_rdst/run_z6pack.sh", "kmod/w413_selftest_sweep.sh",
          "z6root/MANIFEST", "z6root.zip", "z6root/kernelsu.ko", "kmod/ksu_args.txt",
          "kmod/ksu_one_stage.sh"]:
    LIVE[p] = md5(p)[:8]
KO, PS, PK, GATE, SWP, MAN, ZIP = (LIVE["kmod/kernelsu_rc73.ko"], LIVE["kmod/push_ksu.sh"],
                                   LIVE["kmod/w431_pack_z6root.sh"], LIVE["kmod/_tmp_selftest_rdst/run_z6pack.sh"],
                                   LIVE["kmod/w413_selftest_sweep.sh"], LIVE["z6root/MANIFEST"], LIVE["z6root.zip"])
print("  现取：ko=%s push_ksu=%s packer=%s z6pack=%s 总闸=%s MANIFEST=%s zip=%s" % (KO, PS, PK, GATE, SWP, MAN, ZIP))
assert LIVE["z6root/kernelsu.ko"] == KO, "包内 ko 与源件不是同一份"

R = []

# ---------------- DELIVERY.md ----------------
D = "kmod/DELIVERY.md"
R.append((D,
 "- 交付二进制 = `kmod/kernelsu_rc67.ko`（md5 `40e0c25d28b485d84c1d97f1fd044af0`，5,085,584 B）。",
 "- 交付二进制 = `kmod/kernelsu_rc73.ko`（md5 `%s…`，5,086,000 B）。（★10-24 04:4x 从 rc67 换成它：只多 §6.394 那条 `files==NULL` 护栏——"
 "装 fd 的回调踩到正在退出的任务就会 null deref⇒PS_HOLD。**离线结构差**＝`.text` +32 B、`.rodata.str1.1` +134 B(那句 skip 打印)，而 "
 "`vermagic`/`__param`(1240 B)/`__versions`(159 条)/未定义引用(155 个)与 rc67 **逐字相同** ⇒ `kmod/ksu_args.txt` 那五条参数原样吃得下，不需要改 args。"
 "**真窗凭据**＝第 48 发把 ko 当唯一变量那一发(`insmod rc=0 up=729.15`＋`BIND_RC=0`＋`HEALTH=OK`＋`GO_RC=0`，窗活到 insmod+≈1654 秒)。"
 "★**没证到的**：护栏到底挡过一次没有(#170：那一发 `NULLFILES skip` 全程 0，它只给活着的 Manager 排过队)——换默认的理由是\"少了一条已知崩溃路径\"，不是\"治好了什么\"。"
 "上一版交付二进制＝`kmod/kernelsu_rc67.ko`（md5 当时 `40e0c25d…`，5,085,584 B，仍留仓，`KO=kmod/kernelsu_rc67.ko` 就指得回去）" % KO))
R.append((D,
 "1. `kmod/push_ksu.sh` 的回执 `ok kernelsu.ko 40e0c25d28b485d84c1d97f1fd044af0` 与 `ok ksu_args.txt 67199f4898c98371aa3ad0ef6f649e89`（**参数是否上机，只认这两条 md5**）；",
 "1. `kmod/push_ksu.sh` 的回执 `ok kernelsu.ko %s8256b0a199c3957538d272dd`(10-24 04:4x 起默认＝rc73；旧的 `40e0c25d…` 是上一版 rc67 的回执，"
 "别再拿它当判据) 与 `ok ksu_args.txt 67199f4898c98371aa3ad0ef6f649e89`（**参数是否上机，只认这两条 md5**）；" % KO))
R.append((D,
 "**资产与凭据**：`kmod/kernelsu_rc67.ko`＝`40e0c25d…`｜",
 "**资产与凭据**：出货 ko `kmod/kernelsu_rc73.ko`＝`%s…`(★10-24 04:4x 起，带 §6.394 护栏)｜上一版 `kmod/kernelsu_rc67.ko` 当时＝ `40e0c25d…`｜" % KO))
R.append((D, "`kmod/push_ksu.sh`＝`aedb3501…`",
          "`kmod/push_ksu.sh`＝`%s…`(★10-24 04:4x＝默认 ko 从 rc67 换 rc73；上一版 aedb3501)" % PS))
R.append((D, "打包器 `kmod/w431_pack_z6root.sh`＝`90ac0d23…`（★10-24 03:5x 现值＝",
          "打包器 `kmod/w431_pack_z6root.sh`＝`%s…`（★10-24 04:4x 现值＝映射里出货 ko 换成 rc73(带护栏那支)；当时 `90ac0d23`＝" % PK))
R.append((D, "忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`abc21935…`（★10-24 03:5x 现值＝",
          "忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`%s…`（★10-24 04:4x 现值＝**再加 ⑩ 组四口**：包内 kernelsu.ko 必须与映射源件逐字节同一份＋"
          "那支里必须有 `NULLFILES` 护栏串(负对照＝rc67 里 0 条)＋反夹具把映射漂回 rc67 必须红；自数 61→**65 项全绿**；当时 `abc21935`＝" % GATE))
R.append((D, "`MANIFEST`＝`5f5985be…`（★10-24 03:5x 现值＝**#180 重打包**：包内",
          "`MANIFEST`＝`%s…`（★10-24 04:4x 现值＝**出货 ko 换 rc73 那次重打包**：包内 `z6root/kernelsu.ko`＝`%s`；上一组(MANIFEST `5f5985be`／zip `53706528`／包内 ko `40e0c25d`)作废留链；包内" % (MAN, KO)))
R.append((D, "`z6root/w625_seedrestart.sh`＝`72d001c1`，`z6root/kernelsu.ko` 仍 `40e0c25d…`；分发件 `z6root.zip`＝`53706528`",
          "`z6root/w625_seedrestart.sh`＝`72d001c1`，`z6root/kernelsu.ko`＝`%s`(★10-24 起＝rc73)；分发件 `z6root.zip`＝`%s`" % (KO, ZIP)))
R.append((D, "跑通链的三件载荷(ko `40e0c25d`／args `67199f48`／stage `bef1a8a9`)逐字未变，改动只落在“多一条发货腿＋教程第 8 条重写＋两出口文案”；",
          "跑通链里 args `67199f48`／stage `bef1a8a9` 逐字未变，但**10-24 04:4x 出货 ko 已从 rc67 `40e0c25d` 换成 rc73 `%s`**(只多 §6.394 那条护栏，"
          "`vermagic`/`__param`/`__versions`/未定义引用与 rc67 逐字相同⇒五条 args 原样吃得下，离线已核)；⇒ 这一版与认证过那一份的差＝“多一条发货腿＋三把闸＋教程与两出口文案＋**出货 ko 换版**”；" % KO))
R.append((D, "`kmod/w413_selftest_sweep.sh`＝`3fb3776b…`",
          "`kmod/w413_selftest_sweep.sh`＝`%s…`(★10-24 04:5x＝把 w680 接进 py_compile；上一版 3fb3776b)" % SWP))

# ---------------- CONTINUE_HERE.md ----------------
H = "analysis/CONTINUE_HERE.md"
R.append((H, "｜清单 `z6root/MANIFEST`＝`5f5985be…`(21 行)｜教程 `z6root/教程.txt`＝`94d54851…`｜分发件 `z6root.zip`＝`53706528…`(zip 条目 22)｜忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`abc21935…`(**自数 61 项全绿**，含四条反夹具)｜",
          "｜清单 `z6root/MANIFEST`＝`%s…`(21 行)｜教程 `z6root/教程.txt`＝`94d54851…`｜分发件 `z6root.zip`＝`%s…`(zip 条目 22)｜忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`%s…`(**自数 65 项全绿**，含五条反夹具)｜出货 ko `kmod/kernelsu_rc73.ko`＝`%s…`(★10-24 04:4x 起；上一版 rc67 `40e0c25d`)｜推件件 `kmod/push_ksu.sh`＝`%s…`｜" % (MAN, ZIP, GATE, KO, PS)))
R.append((H, "｜总闸 `kmod/w413_selftest_sweep.sh`＝`3fb3776b…`。",
          "｜总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`。" % SWP))
R.append((H, "跑通链的三件载荷 **ko `40e0c25d`／args `67199f48`／stage `bef1a8a9` 逐字未变**，改动只落在\"多一条发货腿＋教程文案＋两出口文案\"。",
          "跑通链的三件载荷里 **args `67199f48`／stage `bef1a8a9` 逐字未变，但 ko 已从 rc67 `40e0c25d` 换成 rc73 `%s`(只多那条护栏，args 兼容已离线核过)**"
          "⇒ 改动面＝\"多一条发货腿＋三把闸＋教程文案＋两出口文案＋出货 ko 换版\"。" % KO))

# ---------------- CURRENT-STATUS.md / W345：把仍写成成对形状的旧值换掉 ----------------
C = "analysis/CURRENT-STATUS.md"
R.append((C, "`kmod/w431_pack_z6root.sh`＝`90ac0d23…`",
          "`kmod/w431_pack_z6root.sh`＝`%s…`(★10-24 04:4x＝出货 ko 映射换 rc73；上一版 90ac0d23)" % PK))
R.append((C, "`z6root/MANIFEST`＝`5f5985be…`",
          "`z6root/MANIFEST`＝`%s…`(★10-24 04:4x 重打包；上一版 5f5985be)" % MAN))
R.append((C, "总闸 `kmod/w413_selftest_sweep.sh`＝`3fb3776b…`",
          "总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(★10-24 04:5x＝w680 接进 py_compile；上一版 3fb3776b)" % SWP))
W = "kmod/W345_RC68_WINDOW.md"
R.append((W, "`kmod/w431_pack_z6root.sh`=`90ac0d23…`（★10-24 03:5x＝",
          "`kmod/w431_pack_z6root.sh`=`%s…`（★10-24 04:4x＝出货 ko 映射换 rc73；当时 90ac0d23＝" % PK))
R.append((W, "`kmod/w431_pack_z6root.sh`=`90ac0d23…`(★10-24 03:5x＝",
          "`kmod/w431_pack_z6root.sh`=`%s…`(★10-24 04:4x＝出货 ko 映射换 rc73；当时 90ac0d23＝" % PK))

# ---------------- 全部门卫通过才写 ----------------
docs = {}
for f, old, new in R:
    if f not in docs:
        docs[f] = io.open(f, encoding="utf-8").read()
    c = docs[f].count(old)
    if c != 1:
        print("[x] %s 的锚点命中 %d(应 1)⇒ 一个文件都不写：%s…" % (f, c, old[:52]))
        sys.exit(1)
    docs[f] = docs[f].replace(old, new)
for f, t in docs.items():
    io.open(f, "w", encoding="utf-8", newline="\n").write(t)
    print("  [OK] 写了 %s" % f)
print("=== w680 完成：出货 ko 登记为 rc73=%s，包=%s，清单=%s ===" % (KO, ZIP, MAN))
