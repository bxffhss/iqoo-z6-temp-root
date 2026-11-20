#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w726_docsync7.py —— 把第 51 发(1 枪＝rc74b 上机)的结论同步进三份入口文档，并把被顶替的哈希「拆掉等号」。
   跑法：PYTHONUTF8=1 python kmod/w726_docsync7.py
   为什么每处替换都先数命中数：**count!=1 就一个字都不写**(例 153/163 那一族——在错形状上硬插＝静默换内容)。
   ★拆等号这条是自家审计 R9 的口径：只有相邻的 `路径`＝`哈希` 才算「当前登记」，历史值必须写成 `当时＝`；
     换完哈希要重跑 w415 看它是否清零，不然这条牙等于没跑。
"""
import hashlib
import io
import os
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CH = os.path.join(R, "analysis", "CONTINUE_HERE.md")
CS = os.path.join(R, "analysis", "CURRENT-STATUS.md")
DL = os.path.join(R, "kmod", "DELIVERY.md")
LB = os.path.join(R, "kmod", "ROUTE-B-OFFSET-INVERSION.md")

W413 = "389c90af"     # 总闸现值(本件已注册进它第 1b 节的 py 闸、w720 已注册进第 1 节的 bash 闸之后现取)

def md5(p):
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()


def rd(p):
    return io.open(p, encoding="utf-8", errors="surrogateescape").read()


def wr(p, s):
    io.open(p, "w", encoding="utf-8", newline="", errors="surrogateescape").write(s)


# ---------------- 1) 拆等号：被这一发顶替的旧登记 ----------------
DEPAIR = [
    (LB, "`kmod/w695_shot51_plan.md`＝`bedb57e9", "`kmod/w695_shot51_plan.md` 当时＝`bedb57e9", 1),
    (LB, "`kmod/w413_selftest_sweep.sh`＝`826e0a92", "`kmod/w413_selftest_sweep.sh` 当时＝`826e0a92", 1),
    (LB, "`kmod/w694_ringwitness.sh`＝`a28f199a", "`kmod/w694_ringwitness.sh` 当时＝`a28f199a", 1),
    (CH, "`kmod/w695_shot51_plan.md`＝`bedb57e9", "`kmod/w695_shot51_plan.md` 当时＝`bedb57e9", 1),
    (CS, "`kmod/w695_shot51_plan.md`＝`bedb57e9", "`kmod/w695_shot51_plan.md` 当时＝`bedb57e9", 1),
    (DL, "`kmod/w695_shot51_plan.md`＝`bedb57e9", "`kmod/w695_shot51_plan.md` 当时＝`bedb57e9", 1),
    (CH, "`kmod/w413_selftest_sweep.sh`＝`826e0a92", "`kmod/w413_selftest_sweep.sh` 当时＝`826e0a92", 2),
    (CS, "`kmod/w413_selftest_sweep.sh`＝`826e0a92", "`kmod/w413_selftest_sweep.sh` 当时＝`826e0a92", 2),
    (DL, "`kmod/w413_selftest_sweep.sh`＝`826e0a92", "`kmod/w413_selftest_sweep.sh` 当时＝`826e0a92", 1),
    (CH, "`kmod/w694_ringwitness.sh`＝`a28f199a", "`kmod/w694_ringwitness.sh` 当时＝`a28f199a", 1),
    (CS, "`kmod/w694_ringwitness.sh`＝`a28f199a", "`kmod/w694_ringwitness.sh` 当时＝`a28f199a", 1),
]

# ---------------- 2) 顶替状态文案(DELIVERY 那条「还没上机」现在不成立了) ----------------
STATUS = [
    (DL,
     "**10-24 15:4x rc74b（§6.415）新登记**：★同样**只是「编好了、离线全绿、还没上机」**，出货默认**仍是 rc73**。",
     "**10-24 15:4x rc74b（§6.415）新登记**：★当时是「编好了、离线全绿、还没上机」⇒ **10-24 17:3x 第 51 发已上机判正(§6.416)**，"
     "但**包里那份 ko 仍是 rc73 `34b3efa8`**，所以出货默认不变(见下面那条 17:3x 登记)。",
     1),
    (CS,
     "2026-10-24 15:4x 更新（本节最新，取代 13:5x 那节）",
     "2026-10-24 15:4x 更新（已被 17:4x 那节取代）",
     1),
]

NEW_CH = """## ★★★★★★★★★★★★★★★★★★ **2026-10-24 16:1x–17:3x 第 51 发(1 枪)：rc74b 真机判正——去重生效(11 个排队 pid 每个恰好 1 次、长命主进程 `fd_ksu=1`、第二轮 `=2`)＋牌子自亮复现＋窗内活到 `insmod+2907 秒`；★同发认账两条：判据⑥「只认主进程」是我写窄了(真性质＝Manager uid 的线程组领头——主进程排队时 comm 还叫 `usap64`)＋`cap=64` 会被 Manager 崩溃风暴吃掉(实测 0.45 次/分钟，本发没观测到真踢)**

- **赢在哪(全是现读，判据开枪前写死在 `kmod/w695_shot51_plan.md`)**：唯一变量＝ko(`18750560…`)，五条 args 逐字不动；
  `[16:42:59] insmod rc=0 up=1993.48`；去重正证分两份件数——装载期全量件 `dmesg.live`(内容覆盖 **1261→2279**，含 insmod)里 `queued self fd` 4 条逐 pid=1，
  当前环两份快照里再 7 条仍逐 pid=1；`dupskip` 最大 **n=78849**、`childskip` 最大 **n=32257**(⇒ 挡住的两支都有证人，不是"不打印＝没挡")；
  `fd_ksu` 单生产者主进程 **1 条**、二轮 **2 条**(第 50 发同位置 14→68→75)；`kzalloc(ATOMIC) failed`/`task_work_add rc`/`NULLFILES skip`/`signal 6` **全 0**；boot_id 全程不变。
- ★**认账①(判据的字面 vs 性质)**：`queued` 的 comm 里有 `crash_dump64`/`libksud.so`/`usap64`，**不是"只有主进程"**；但每条 `seen Manager` 的 `uid=` 都是 10104
  ⇒ 谓词真正圈住的是「**Manager uid 的线程组领头**」。`crash_dump64` 由 zygote(0)生再降权到 10104 ⇒ "同 uid 父子"那一挡天然挡不住它。
  **机制成立的正面证据恰在这**：主进程 21205 的 fd 是在它还叫 `usap64` 时装进去的 ⇒ 腿第 1 敲 **0 拍**命中(`SR-ROUND r=1 pid=21205 fd=2`)，第 2 敲 `SR-ALREADY` 且 pidof 一字不变。
- ★**认账②(没测到但算得出来的风险)**：`ksu_mgr_birth_cap`=64 是**只涨不跌**的 `total`，helper 也在消费——`total` 7→21 用了 1842 秒(≈0.45/分钟)，
  **一次 Manager 重启的 0.37 秒内吃 6 次** ⇒ 约 2.4 小时见底，之后本 boot 不再"出生即装"(新开的 Manager 回 `不支持`，只有恢复腿还能刷回来)。
  三条候选(都还没做，要用户点头)：**A** 抬 cap(一行，默认值变＝重编＋再一发)／**B** 谓词加"cmdline 含 `me.weishu.kernelsu`"(最贴原意，要在 probe 里 nofault 读 argv)／**C** 不动，把"cap 用尽"写进交付口径。
- **出货默认不变的理由**：包里那份 ko 还是 rc73 `34b3efa8`——"升默认"要连着 #178(**第 52 发＝当前版包真机一键认证，连 ko 一起认**)，这发**没打包**(两个变量混一发＝红了说不出是谁造成的)。
- **收尾(顺序照 §6.414 做到)**：`/data/adb` `[. .. .suwtest ksu ksud]`→`[. ..]`(root 腿自己回读)→ `w558_rm3.sh`(151 条)→ shell 侧补删这一发新名字的 10 件＋`ls` 复证(只剩 5 件工具腿)→ `w426_enforce.sh` 翻回 `Enforcing` → `adb reboot`。
  ★`boot.reason.history` 最新一条＝`reboot,shell,1792834324`(正对我们敲的那刻)，而 `ro.boot.bootreason` 报 `HARD_RESET/PS_HOLD` ⇒ **"分不了收尾 vs 异常复位"第三次当场兑现**，别拿 bootreason 当结论。
- **仪器教训四条(都属 例 176 那一族，详见 §6.416)**：①我又拿 `/system/bin/su` 从 adb 侧当 root 通道(改道只对 app 域＋Permissive 成立，PC 侧唯一口径是 `bash kmod/w211_ui.sh rleg <腿>`)；
  ②**重推没 chmod** ⇒ 腿 `exit=126`(§6.414 那条四步闸我只做了三步)；③覆盖区间用**行首**正则算 ⇒ `dmesg.live` 的行带 `<6>` 前缀，我第一次只数到 1899/19591 行、把覆盖读成 13 秒，差点判"装载期不在覆盖内"；
  ④同一条腿产物名固定 ⇒ 第二次调用覆盖第一次(⑨ 那两敲必须一敲一拉)。
- **登记(现取)**：候选 ko `kmod/kernelsu_rc74b.ko`＝`18750560…`(仍未进包)｜开枪判据＋读数 `kmod/w695_shot51_plan.md`＝`e2315683…`｜装载期解析 `kmod/w719_ring_reconcile.py`＝`f450dad5…`｜全量证人腿 `kmod/w720_ksubirth_dump.sh`＝`5fec8b11…`｜读数腿 `kmod/w690_ksubirth.sh`＝`95706ae8…`｜装载期证人腿 `kmod/w694_ringwitness.sh`＝`7b554de7…`｜清理件 `kmod/w558_rm3.sh`＝`e2314525…`(151 条)｜构建驱动 `kmod/remote_ksu_rc74b.sh`＝`c0eca9dc…`｜补丁件 `kmod/w689_add_birthfd2.py`＝`8d01f1da…`｜逻辑测试 `kmod/w691_birth_test.py`＝`0142b3cd…`｜文档同步 `kmod/w726_docsync7.py`｜总闸 `kmod/w413_selftest_sweep.sh`＝`@@W413@@…`｜出货 ko(未变) `kmod/kernelsu_rc73.ko`＝`34b3efa8…`＋`kmod/ksu_args.txt`＝`67199f48…`。
- **机器现态**：`Enforcing`、`mod=0`、`/product/bin` 挂载＝0、boot_id `ccde849f`、**10-24 枪数＝2**(第 50、51 发)。
- **接手只要 5 条命令**：⓪`bash kmod/w413_selftest_sweep.sh`(动工具链之前先跑，看 rc=0＋`w415` 命中 0)→
  ①**先定 cap 那一格**(A 抬帽／B cmdline 谓词／C 写进交付口径——A/B 都要"重编＋一发")→
  ②`bash kmod/push_ksu.sh` 之前把这一发用的每条腿重推＋**chmod 755**＋设备 `sh -n`＋两端 md5(`w690`/`w694`/`w720`/`w625`/`w165b`/`w558`/`w426`)→
  ③要上机就 `KO=kmod/kernelsu_rc74b.ko I_KNOW=1 bash kmod/go.sh`(1 boot 只 1 枪；判据先写死)→
  ④root 腿全部走完再 `bash kmod/w211_ui.sh rleg w426_enforce.sh`，读回 `enforce=1` 才收尾＋reboot。

"""

NEW_CS = """## ★★★★★★★★★★★★★★★★★★ 2026-10-24 17:4x 更新（本节最新，取代 15:4x 那节）—— **第 51 发(1 枪)：rc74b 真机判正——去重生效(每 pid 恰好 1 次、主进程 `fd_ksu=1`)＋牌子自亮复现＋窗内 `insmod+2907 秒`；★同发认账两条：「只认主进程」这句判据写窄了(真性质＝Manager uid 的线程组领头)＋`cap=64` 会被 Manager 崩溃风暴吃掉(0.45 次/分钟，未观测到真踢)**

- **一手读数**：`[16:42:59] insmod rc=0 up=1993.48`(ko `18750560…`、args `67199f48…` 逐字未动)；`queued self fd` 两份件合计 11 条＝**逐 pid 恰 1**；
  `dupskip` n 最大 **78849**、`childskip` n 最大 **32257**；`fd_ksu` 单生产者 1 条／二轮 2 条；`kzalloc failed`/`task_work_add rc`/`NULLFILES skip`/`signal 6` 全 0；boot_id `12afb83f` 全程不变。
- ★**判据⑥按字面判负、按性质判正**：`queued` 的 comm 有 `usap64`/`crash_dump64`/`libksud.so`(uid 全是 10104)；主进程 21205 的 fd 是在它还叫 `usap64` 时装进去的 ⇒ **腿第 1 敲 0 拍命中**，第 2 敲 `SR-ALREADY` 且 pidof 不变。
- ★**新风险(算出来但没测到真踢)**：`cap`=64 只涨不跌，`total` 7→21 用 1842 秒；一次 Manager 重启 0.37 秒吃 6 次 ⇒ 约 2.4 小时见底，之后本 boot 只能靠恢复腿。三候选 A 抬 cap／B cmdline 谓词／C 写进口径(**待用户点头**)。
- **默认不变**：包里 ko 仍 rc73 `34b3efa8`；升默认必须连着 **#178＝第 52 发(当前版包真机一键认证，连 ko 一起认)**。
- **现值(现取)**：`kmod/kernelsu_rc74b.ko`＝`18750560…`｜`kmod/w695_shot51_plan.md`＝`e2315683…`｜`kmod/w719_ring_reconcile.py`＝`f450dad5…`｜`kmod/w720_ksubirth_dump.sh`＝`5fec8b11…`｜`kmod/w690_ksubirth.sh`＝`95706ae8…`｜`kmod/w694_ringwitness.sh`＝`7b554de7…`｜`kmod/w558_rm3.sh`＝`e2314525…`｜总闸 `kmod/w413_selftest_sweep.sh`＝`@@W413@@…`｜文档同步 `kmod/w726_docsync7.py`。
- **机器现态**：`Enforcing`、`mod=0`、boot_id `ccde849f`、**10-24 枪数＝2**。

"""

NEW_DL = """**10-24 17:3x 第 51 发（§6.416，1 枪）新登记**：★**rc74b 真机判正**——去重生效(两份件合计 11 条 `queued self fd`＝**逐 pid 恰 1**；`dupskip` n 最大 78849、`childskip` n 最大 32257)、
主进程 `fd_ksu` 单生产者 **1** 条／第二轮 **2** 条(第 50 发同位置 14→68→75)、force-stop 后**只用 `am start`** 牌子自己回 `工作中／32601-2／越狱／页签 4`(焦点已断言)、窗内活到 `insmod+2907 秒` 且 `signal 6`=0。
★**但这发同时认账两条**：①判据里"只认主进程"是我写窄了——`queued` 的 comm 有 `usap64`/`crash_dump64`/`libksud.so`(uid 全 10104) ⇒ 真性质＝「**Manager uid 的线程组领头**」；
②`ksu_mgr_birth_cap`=64 会被 Manager 崩溃风暴按 **0.45 次/分钟** 吃掉(一次重启的 0.37 秒内吃 6 次) ⇒ 约 2.4 小时见底后本 boot 只剩恢复腿可用；**A 抬 cap／B cmdline 谓词／C 写进交付口径** 三选一等用户点头。
★**出货默认仍是 rc73**(`34b3efa8`)：这发**没打包**，升默认连着 #178(第 52 发＝当前版包真机一键认证，**连 ko 一起认**)。
新增两件仪器：读数落盘腿 `kmod/w720_ksubirth_dump.sh`＝`5fec8b11…`(形状＝"原样落盘＋PC 侧数"，不在设备侧数命中)＋离线解析 `kmod/w719_ring_reconcile.py`＝`f450dad5…`(★覆盖区间必须**行内**搜：`dmesg.live` 的行带 `<6>` 前缀，按行首数只数到 1899/19591 行)。

"""

def apply_reps(reps, label):
    """先全部数命中(在同一份工作文本上累加)，任何一处不符 ⇒ 一个字都不写。"""
    snap = {}
    todo = []
    for path, old, new, want in reps:
        s = snap.get(path, rd(path))
        got = s.count(old)
        snap[path] = s
        print("  [%s] %s 锚命中=%d(期望 %d)" % (label, os.path.basename(path), got, want))
        if got != want:
            print("[x] %s 锚 %s 命中 %d 次(期望 %d) ⇒ 全部不写，先把锚重新从文件里取" % (label, old[:52], got, want))
            sys.exit(1)
        todo.append((path, old, new, want))
    for path, old, new, want in todo:
        snap[path] = snap[path].replace(old, new)     # 命中数已由 want 钉死，这里全数替换
    for path in snap:
        wr(path, snap[path])


print("=== w726 文档同步(第 51 发) ===")
if W413 == "@@W413@@":
    print("[x] W413 还是占位符 ⇒ 先把本件注册进 w413、取到总闸新值再跑(否则文档里会写一个假数)")
    sys.exit(1)
# 第一阶段：拆等号(全文检查＋写回)
apply_reps(DEPAIR, "拆等号")
# 第二阶段：顶替状态文案
apply_reps(STATUS, "状态文案")


def insert_before_heading(path, needle, block, mark, label, mode="heading"):
    """把 block 插到 needle 所在处之前；needle 用正文片段，不靠我数星号。
       mode=heading ⇒ 退到它所属的 `## ` 标题行(入口文档的新节)；
       mode=line    ⇒ 就插在那一行前面(DELIVERY 那种"一条登记"的排版)。"""
    s = rd(path)
    if mark in s:
        print("  [skip] %s 已经有这一节(标记=%s)⇒ 幂等：不重复插" % (label, mark[:22]))
        return
    i = s.find(needle)
    if i < 0:
        print("[x] %s 找不到片段 %s ⇒ 不写" % (label, needle))
        sys.exit(1)
    if s.count(needle) != 1:
        print("[x] %s 片段 %s 命中 %d 次(要 1) ⇒ 不写" % (label, needle, s.count(needle)))
        sys.exit(1)
    if mode == "line":
        pos = s.rfind("\n", 0, i) + 1
    else:
        pos = s.rfind("\n## ", 0, i)
        if pos < 0:
            print("[x] %s 片段 %s 上面找不到 `## ` 标题行 ⇒ 不写(形状和预期不同)" % (label, needle))
            sys.exit(1)
        pos += 1
    wr(path, s[:pos] + block.replace("@@W413@@", W413) + s[pos:])
    print("  [插入] %s 新登记写在偏移 %d(mode=%s)" % (label, pos, mode))


insert_before_heading(CH, "2026-10-24 14:5x–15:4x 收口", NEW_CH, "第 51 发(1 枪)：rc74b 真机判正", "CONTINUE_HERE.md")
insert_before_heading(CS, "2026-10-24 15:4x 更新", NEW_CS, "17:4x 更新（本节最新", "CURRENT-STATUS.md")
insert_before_heading(DL, "**10-24 15:4x rc74b（§6.415）新登记**", NEW_DL, "**10-24 17:3x 第 51 发（§6.416", "DELIVERY.md", mode="line")


for path, label in ((CH, "CONTINUE_HERE"), (CS, "CURRENT-STATUS"), (DL, "DELIVERY")):
    left = rd(path).count("@@W413@@")
    print("  ★残留占位符检查 %s = %d(必须 0)" % (label, left))
    if left:
        print("[x] %s 里还留着占位符 ⇒ 停" % label)
        sys.exit(1)

print("  写完后哈希：CONTINUE=%s CURRENT=%s DELIVERY=%s 台账=%s 本件=%s"
      % (md5(CH)[:8], md5(CS)[:8], md5(DL)[:8], md5(LB)[:8], md5(os.path.abspath(__file__))[:8]))
print("  下一步：跑 w413 总闸＋w415 文档审计(期望命中 0)")
print("=== w726 完成 ===")

