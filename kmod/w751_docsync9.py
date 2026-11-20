#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w751_docsync9.py —— 把第 52 发(1 枪)同步进两份入口文档：主判据判**负**(未复现)＋两格未测＋下一步换读法。
   跑法：PYTHONUTF8=1 python kmod/w751_docsync9.py
   ★同 w726/w735：任何锚的命中数不是期望值就**一个字都不写**；插入用正文片段当锚；有标记就跳过(幂等)。
"""
import hashlib
import io
import os
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CH = os.path.join(R, "analysis", "CONTINUE_HERE.md")
CS = os.path.join(R, "analysis", "CURRENT-STATUS.md")
W413 = "9bdf9100"     # 总闸现值(把 w745 注册进去之后现取)


def md5(p):
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()[:8]


def rd(p):
    return io.open(p, encoding="utf-8", errors="surrogateescape").read()


def wr(p, s):
    io.open(p, "w", encoding="utf-8", newline="", errors="surrogateescape").write(s)


NEW_CH = u"""## ★★★★★★★★★★★★★★★★★★ **2026-10-24 20:32–21:33 第 52 发(1 枪)：主判据判「负」——在 rc74b 这一支上「牌子自己灭」没复现(连采 8 分钟＋BACK＋重进，`不支持`=0 次)；★新证：出生即装连 insmod 之前就活着的老进程也补装；两格未测(前 8.5 分钟被 vivo USB 模态对话框抢焦点／超级用户页压根没进去)**

- **形状**：唯一变量＝ko(`kernelsu_rc74b.ko`＝`18750560…` 与第 51 发逐字同一支)＋args 五条不动＋写回 6 条桩＋单条目名单＋零实验开关；**不打包、不动 cap**。判据八条开枪前写死在 `kmod/w730_shot52_plan.md`＝`4b90d755…`(读数已追加在同一件里)。
- **读数(判正的那几格)**：`[20:43:29] insmod rc=0 up=518.50`、boot_id `9695b89a` 全程不变、**窗内活到 `insmod+2601 秒`**(≈43 分钟)；去重复现(装载期件 `dmesg.live` HB 覆盖 517.23→812.25：`queued self fd` 3 条**逐 pid 恰 1**，主进程只见 `dupskip`)；**不泄漏**(root 采样 34 轮 `fd_ksu` **恒＝3**，收尾前独立复读仍 3 条)；`kzalloc failed`/`task_work_add rc`/`cap`/`NULLFILES skip`/`signal 6` **全 0**；`Seccomp=`**2**(现读，app 域 filter 在场)。
- ★**主判据判负＝症状未复现**：清掉抢焦点的东西之后，**26 轮(约 8 分钟)每轮焦点断言 OK 且 `工作中／32601-2／越狱`**，BACK 后 3 格、重进后 3 格都仍亮，CSV 里 `工作中` 33 次／`不支持` **0 次**。⇒ **"fd 在表里＋进程活着"时它不掉** ⇒ **"长期存在"的瓶颈不是 cap／谓词(#185 的 A/B)**。
- ★★**但这一发没有触发"重算失败"那支**：`KSUBEAT` 改道链 `SU0/SD4/SU1` 全程 **0 次**、`logcat -b crash` 命中 0 ——因为**根本没进超级用户页**(见下) ⇒ 既不能证 (c) 也不能驳 (c)。#184 的优先级因此改写：从"为什么灭"变成**"在什么条件下才灭"**，下一读的写法＝**真的用 UI 点进那一页**(`ui_grant.sh` 那条点击路)，或直接 `force-stop` 之后再深链；**在捕获到条件之前不许动 ko**。
- ★**新证据(正向)**：Manager `pid=14437` 的 `start_ticks=8651`(≈开机 86.5 秒)**远早于 insmod(518.5 秒)**，它照样被排队并拿到 `=> fd=88` ⇒ **出生即装会补装活着的老进程**；交付上"先装 ko 后开 Manager"与"Manager 已开着再装 ko"两种顺序都拿得到牌子。
- **两格未测(不许被当成结论)**：①**前 8.5 分钟整段作废**——vivo 的 **USB 用途选择对话框**(`pkg=android`，"仅充电／传输照片／管理文件／连接车辆／取消")模态抢走焦点与无障碍树，40 格读数**字节数一字不变** ⇒ 记未测；★**绝不点"取消"**(可能把 adb 数据通道一起关掉)，`input keyevent 4` 关掉后立刻读到 `工作中`。②**"卡一下再闪退"没测到**——`am start -d ksu://action/superuser` 走"delivered to currently running top-most instance"，页面逐字未变、页签仍 3 ⇒ **深链≠切页**。
- ★**仪器教训三条**(例 176 那一族)：**"UI 读不到"与"牌子灭了"同形**——读数一动不动本身就是报警，挡住我的只有 `mCurrentFocus`＋`包在场=` 两道断言；主判据是显示层时仪器被挡要**先修仪器再重采**(→ `w745_badge_watch2.sh`：每格先关模态框＋顶回前台＋再断言，两拍读不到才记 UNTESTED，同窗 0 额外枪只花时间)；**深链不等于切页**。
- **登记(现取)**：判据＋读数 `kmod/w730_shot52_plan.md`＝`4b90d755…`｜修正版采样器 `kmod/w745_badge_watch2.sh`＝`08b13988…`｜root 采样器 `kmod/w731_root_sampler.sh`＝`5140dd57…`(设备副本同 md5、两壳 selfcheck 全绿)｜被挡住那版原件 `kmod/w732_badge_watch.sh`＝`a35e7f83…`(保留当教学件)｜抽取器 `kmod/w733_badgetext.py`＝`e6072c1d…`｜总闸 `kmod/w413_selftest_sweep.sh`＝`9bdf9100…`｜文档同步 `kmod/w751_docsync9.py`｜候选 ko `kmod/kernelsu_rc74b.ko`＝`18750560…`(**仍只上机过、仍未进包**)｜出货 ko(未变) `kmod/kernelsu_rc73.ko`＝`34b3efa8…`＋`kmod/ksu_args.txt`＝`67199f48…`。
- **机器现态**：`Enforcing`、`mod=0`、`/product/bin` 挂载＝0、boot_id `32b27333`、**10-24 枪数＝3**(第 50/51/52 发)。★开窗前的只读检查抓到一次**未归因基线冷启**(19:09 `cold,charger`＋`USB_CHARGER/PS_HOLD`，当时厂状态)＝§6.149 那一族的第二枚，与 ko 无关。
- **接手只要 4 条命令**：⓪`bash kmod/w413_selftest_sweep.sh`(rc=0，`run_w731` 那条要在)→①`bash kmod/w415_doc_audit.py`(命中 0)→②每条腿**重推＋chmod 755＋设备 `sh -n`＋两端 md5**→③要上机就 `KO=kmod/kernelsu_rc74b.ko I_KNOW=1 bash kmod/go.sh`；★**但下一发该做的是"真点进超级用户页"那一格**(它能在任何一支 ko 上跑，不额外烧枪的条件是同一个窗里做)，跑完才谈 #178(第 53 发＝当前版包真机一键认证)。

"""

NEW_CS = u"""## ★★★★★★★★★★★★★★★★★★ 2026-10-24 21:4x 更新（本节最新，取代 19:5x 那节）—— **第 52 发(1 枪)：主判据判「负」＝「牌子自己灭」在 rc74b 上没复现；新证「老进程也被补装」；两格未测(模态对话框抢焦点／压根没进超级用户页)**

- **判正**：`[20:43:29] insmod rc=0 up=518.50`、boot_id `9695b89a` 不变、窗内活到 `insmod+2601 秒`；去重(装载期件 `queued self fd` 3 条逐 pid 恰 1)、不泄漏(`fd_ksu` 恒＝3，跨 38 分钟)、`cap`/`kzalloc failed`/`NULLFILES skip`/`signal 6` 全 0、`Seccomp=2` 现读。
- ★**主判据判负(未复现)**：清掉抢焦点的东西后 26 轮约 8 分钟每轮都 `工作中／32601-2／越狱`，BACK 后与重进后都仍亮，`不支持` **0 次** ⇒ **"长期存在"的瓶颈不是 cap／谓词**(#185 的 A/B 不是解)。
- ★**但"重算失败"那支这发没被触发**：改道链 `SU0/SD4/SU1` 全程 0 次、crash 命中 0(因为没真的进超级用户页) ⇒ **(c) 既未证也未驳**；#184 改成**"在什么条件下才灭"**，下一读＝**用 UI 真点进那一页**(或 `force-stop` 后深链)，**捕获条件之前不动 ko**。
- ★**新证据**：`pid=14437` 的 `start_ticks=8651` 早于 `insmod up=518.5`，仍被排队并拿到 `=> fd=88` ⇒ **出生即装连活着的老进程也补装**(两种开机顺序都拿得到牌子)。
- **两格未测**：①前 8.5 分钟被 vivo **USB 用途选择对话框**(模态、`pkg=android`)抢走无障碍树——★**别点"取消"**(可能一起关掉 adb)，用 `input keyevent 4`；②`am start -d ksu://action/superuser` 走"投递给已存在实例"、页面逐字不变 ⇒ **深链≠切页**。
- **现值(现取)**：`kmod/w730_shot52_plan.md`＝`4b90d755…`｜`kmod/w745_badge_watch2.sh`＝`08b13988…`｜`kmod/w731_root_sampler.sh`＝`5140dd57…`｜`kmod/w732_badge_watch.sh`＝`a35e7f83…`｜`kmod/w733_badgetext.py`＝`e6072c1d…`｜总闸 `kmod/w413_selftest_sweep.sh`＝`9bdf9100…`｜文档同步 `kmod/w751_docsync9.py`｜候选 ko 仍 `18750560…`(**仍未进包，默认仍 rc73 `34b3efa8…`**)。
- **机器现态**：`Enforcing`、`mod=0`、boot_id `32b27333`、**10-24 枪数＝3**。★开窗前只读检查抓到 19:09 一次未归因基线冷启(厂状态，与 ko 无关)。

"""


def depair_and_insert(path, depair, needle, block, mark, label, declaim=None):
    s = rd(path)
    for old, new, want in depair:
        got = s.count(old)
        print("  [%s] 拆等号命中=%d(期望%d)" % (label, got, want))
        if got != want:
            print("[x] %s 锚不符 ⇒ 一个字都不写" % label)
            sys.exit(1)
        s = s.replace(old, new)
    if mark in s:
        print("  [skip] %s 已有第 52 发那节 ⇒ 幂等不重复插" % label)
    else:
        if s.count(needle) != 1:
            print("[x] %s 插入锚 %s 命中 %d(要 1) ⇒ 不写" % (label, needle[:32], s.count(needle)))
            sys.exit(1)
        pos = s.rfind("\n## ", 0, s.find(needle))
        if pos < 0:
            print("[x] %s 锚上面找不到 `## ` 标题行 ⇒ 不写" % label)
            sys.exit(1)
        s = s[:pos + 1] + block + s[pos + 1:]
        print("  [插入] %s 新节写在偏移 %d" % (label, pos + 1))
    if declaim:
        old, new = declaim
        if s.count(old) == 1:
            s = s.replace(old, new)
            print("  [撤声明] %s 的『本节最新』已撤下" % label)
    wr(path, s)


print("=== w751 文档同步(第 52 发) ===")
depair_and_insert(
    CH,
    [(u"`kmod/w413_selftest_sweep.sh`＝`10ba03e7…`", u"`kmod/w413_selftest_sweep.sh` 当时＝`10ba03e7…`", 1)],
    u"2026-10-24 16:1x–17:3x 第 51 发(1 枪)", NEW_CH, u"第 52 发(1 枪)：主判据判「负」", "CONTINUE_HERE.md")
depair_and_insert(
    CS,
    [(u"总闸 `kmod/w413_selftest_sweep.sh`＝`@@W413@@…`", u"总闸 `kmod/w413_selftest_sweep.sh`＝`9bdf9100…`", 0),
     (u"`kmod/w413_selftest_sweep.sh`＝`389c90af`", u"`kmod/w413_selftest_sweep.sh` 当时＝`389c90af`", 0),
     (u"总闸 `kmod/w413_selftest_sweep.sh`＝`10ba03e7…`", u"总闸 `kmod/w413_selftest_sweep.sh` 当时＝`10ba03e7…`", 1)],
    u"2026-10-24 19:5x 更新", NEW_CS, u"21:4x 更新（本节最新", "CURRENT-STATUS.md",
    declaim=(u"2026-10-24 19:5x 更新（本节最新，取代 17:4x 那节）", u"2026-10-24 19:5x 更新（已被 21:4x 那节取代）"))

for path, label in ((CH, "CONTINUE_HERE"), (CS, "CURRENT-STATUS")):
    left = rd(path).count("@@W413@@")
    print("  ★残留占位符 %s=%d(必须 0)" % (label, left))
    if left:
        sys.exit(1)

print("  写完后哈希：CONTINUE=%s CURRENT=%s" % (md5(CH), md5(CS)))
print("  下一步：跑 w413(期望 rc=0)＋w415(期望命中 0)")
print("=== w751 完成 ===")
