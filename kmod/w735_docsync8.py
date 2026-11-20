#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w735_docsync8.py —— 把"第 52 发已备妥(0 枪)"这件事同步进两份入口文档，并把被顶替的总闸哈希拆掉等号。
   跑法：PYTHONUTF8=1 python kmod/w735_docsync8.py
   ★同 w726：count!=1 就一个字都不写；插入用正文片段当锚(不靠我数星号)；已存在标记就跳过(幂等)。
"""
import hashlib
import io
import os
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CH = os.path.join(R, "analysis", "CONTINUE_HERE.md")
CS = os.path.join(R, "analysis", "CURRENT-STATUS.md")


def md5(p):
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()[:8]


def rd(p):
    return io.open(p, encoding="utf-8", errors="surrogateescape").read()


def wr(p, s):
    io.open(p, "w", encoding="utf-8", newline="", errors="surrogateescape").write(s)


DEPAIR = [
    (CH, "`kmod/w413_selftest_sweep.sh`＝`389c90af", "`kmod/w413_selftest_sweep.sh` 当时＝`389c90af", 1),
    (CS, "`kmod/w413_selftest_sweep.sh`＝`389c90af", "`kmod/w413_selftest_sweep.sh` 当时＝`389c90af", 1),
]

NEW_CH = u"""## ★★★★★★★★★★★★★★★★★★ **2026-10-24 19:3x–19:5x 收口：0 枪：第 52 发的形状与仪器已备妥——主判据从"牌子亮一次"换成"牌子会不会自己灭"(用户一手＋§6.417/§6.418/§6.419 三条离线)**

- **为什么换主判据**：第 51 发已经把"亮一次＋逐 pid 恰 1＋不泄漏"判正了(§6.416)，再复现一遍增量≈0。用户一手新观察改变问题定性：**挂着不动一直亮、约 0.5 分钟后点返回键掉 `不支持`；改点超级用户则"卡一下再闪退"** ⇒ ①查询**确会随导航重新求值**(§6.406 那句"进程启动一次性"作废)；②真正要答的是"重算时哪一支取不到"。
- **本轮离线定案(三条，全部 0 枪)**：
  §6.417 现扫官方 v3.3.0 `libkernelsu.so`(14480 B)⇒ **牌子的输入面只有"自己 fd 表里有没有 `[ksu_driver]`＋那个 fd 的 ioctl"，无守护、无名单**(我"要常驻 ksud"那句猜测当场作废)；
  §6.418 现扫 `classes.dex`⇒ 超级用户那类页走 **libsu 的 shell/RootService**(`Shell check timeout`／`cp /data/adb/ksu/.allowlist`／`/system/bin/app_process`＋`RootServerMain`／`libksud.so`／`KsuCli`)；
  §6.419 ★**自查驳掉我自己的归因**："死于 app 域 seccomp `reboot(142)`"那句**不成立**——那面墙的载体是 **rc≤55 旧 shim 的超调用传输**，rc56 起出货 shim 已换成扫 fd；且 #113/#118 早证 **app 域 `/system/bin/su` 能出 root**。⇒ "灭"目前**三支未排除**：(a) fd 没了／(b) RootService 的 daemon·app_process 协议不成立／**(c)** 真撞 seccomp。
- **决定**：**#110(内核 escape)先关着**(前提未证)；**#185 的 A/B 降级**为"只决定进程被回收后能不能**自己回亮**"，不是"灭"的解；**#178(当前版包真机一键认证)顺延为第 53 发**——别把默认升到一支我们还不知道能不能解决"灭"的 ko 上，也别让三腿跑在 rc73 形状上(那里 (a) 必然发生，测不出 (b)/(c))。
- **第 52 发的形状与判据(开枪前写死)**：`kmod/w730_shot52_plan.md`＝`96328b2c…`——唯一变量＝ko(`18750560…`，五条 args 逐字不动，**不打包、不动 cap**)；八条判据里 ④⑤⑥ 是主判据：**放前台不动 8.5 分钟每 15 秒一行**(不许出现 `不支持`)、**导航触发格**(BACK→连读 3 格；超级用户深链→连读 4 格＋抓 `logcat -b crash`)、**三分家同刻读数**(`Seccomp` 现值＋内核 `KSUBEAT` 改道链是否为该 uid 出现＋同 up 的 `fd_ksu`)。判读口径：**改道链没出现＝(a)/(b)；链出现了又死于 SIGSYS＝(c)**。
- **三件新仪器(都过了双向自测)**：
  root 侧采样器 `kmod/w731_root_sampler.sh`＝`5140dd57…`(设备副本同 md5、mksh `sh -n` rc=0、**PC bash 与设备 mksh 两壳 selfcheck 全绿**；9 行夹具里 4 行含 `KSUBIRTH`、半行 `KSUBIR` 不计、`dupskip` 取**末**条、`SU链` 只认 SU0/SD4/SU1)；
  PC 侧牌子采样器 `kmod/w732_badge_watch.sh`＝`a35e7f83…`；抽取器 `kmod/w733_badgetext.py`＝`e6072c1d…`(★CJK 只能 pull 回来本地解析，`adb shell cat` 会吞成 [Binary output])。
- ★**本轮我自己坏过的三处(都属 例 176 那一族，全部当场抓到当场修)**：①把循环套进 `sh -c '...'` ⇒ 内层单引号与外层配对，**`bash -n` 照样过但语义已变**(改成"自己带 `--loop` 再叫自己一次")；②selfcheck 夹具路径写死 `/data/local/tmp` ⇒ PC 侧整组判红(改成**按平台现选**)；③**把 task id 当台账编号连错两次**(内部 id≠标题里的 `#NN`)⇒ #176/#174 被我覆盖，已按 §6.407/§6.405 重建并各自标注"以 md 为准"。
- **登记(现取)**：第 52 发判据 `kmod/w730_shot52_plan.md`＝`96328b2c…`｜root 采样 `kmod/w731_root_sampler.sh`＝`5140dd57…`｜牌子采样 `kmod/w732_badge_watch.sh`＝`a35e7f83…`｜抽取 `kmod/w733_badgetext.py`＝`e6072c1d…`｜总闸 `kmod/w413_selftest_sweep.sh`＝`10ba03e7…`(已把上面三件接进 `bash -n`／`py_compile`，并新增 `run_w731` 那条 item)｜上一发读数 `kmod/w695_shot51_plan.md`＝`e2315683…`｜候选 ko `kmod/kernelsu_rc74b.ko`＝`18750560…`(**仍未进包**)｜出货 ko(未变) `kmod/kernelsu_rc73.ko`＝`34b3efa8…`＋`kmod/ksu_args.txt`＝`67199f48…`。
- **机器现态**：`Enforcing`、`mod=0`、`/product/bin` 挂载＝0、boot_id `ccde849f`、**10-24 枪数＝2**；三件仪器已在设备上(`w731` 已推＋chmod＋两壳验过)。**今晚不再打**(深夜不连打)，第 52 发等下一个自然窗且要用户点头。
- **接手只要 5 条命令**：⓪`bash kmod/w413_selftest_sweep.sh`(看 rc=0；`run_w731` 那条 item 必须在)→
  ①`bash kmod/w415_doc_audit.py`(命中要 0)→
  ②把这一发要用的每条腿**重推＋chmod 755＋设备 `sh -n`＋两端 md5**(`w731`/`w690`/`w694`/`w720`/`w625`/`w165b`/`w558`/`w426`)→
  ③`KO=kmod/kernelsu_rc74b.ko I_KNOW=1 bash kmod/go.sh`(1 boot 只 1 枪；判据已写死在 `kmod/w730_shot52_plan.md`)→
  ④开窗后先派 `bash kmod/w211_ui.sh rleg w731_root_sampler.sh`(**只派这一次**，之后 8.5 分钟别再派 rleg——suw 顶前台会改掉焦点)，再 `bash kmod/w732_badge_watch.sh 40 12 shot52`，收尾照 §6.416 的顺序。

"""

NEW_CS = u"""## ★★★★★★★★★★★★★★★★★★ 2026-10-24 19:5x 更新（本节最新，取代 17:4x 那节）—— **0 枪：第 52 发形状已备妥；主判据换成"牌子会不会自己灭"；#110 关着、#178 顺延第 53 发**

- **用户一手改了问题**：挂着不动一直亮 → 约 0.5 分钟**点返回键**掉 `不支持`；点超级用户则**卡一下再闪退** ⇒ 查询**会随导航重新求值**(§6.406"一次性"作废)；要答的是"重算时哪一支取不到"。
- **三条离线定案**：§6.417 牌子的输入面**只有** fd 扫描＋那个 fd 的 ioctl(无守护、无名单)；§6.418 超级用户页走 libsu 的 shell/RootService(`Shell check timeout`／`app_process`＋`RootServerMain`／`libksud.so`)；§6.419 ★**"死于 `reboot(142)` seccomp"被我驳回落回未证**(那面墙的载体是 rc≤55 旧 shim 的传输；#113/#118 已证 app 域 su 能出 root)⇒ 三支未排除：(a) fd 没了／(b) RootService 协议／(c) seccomp。
- **第 52 发**＝唯一变量 ko(`18750560…`，不打包、不动 cap)＋八条判据写死在 `kmod/w730_shot52_plan.md`＝`96328b2c…`：④放前台 8.5 分钟每 15 秒一行不许灭、⑤BACK 与超级用户深链两格导航触发、⑥`Seccomp` 现值＋`KSUBEAT` 改道链＋同 up 的 `fd_ksu` 三分家(口径：**链没出现＝(a)/(b)；链出现又死于 SIGSYS＝(c)**)。
- **新仪器三件(两壳自测全绿)**：`kmod/w731_root_sampler.sh`＝`5140dd57…`、`kmod/w732_badge_watch.sh`＝`a35e7f83…`、`kmod/w733_badgetext.py`＝`e6072c1d…`；总闸 `kmod/w413_selftest_sweep.sh`＝`10ba03e7…`(三件已接入＋新增 `run_w731` item)。
- ★**本轮我自己坏在三处**：`sh -c '...'` 内层单引号(**语法过≠语义对**)、selfcheck 夹具路径写死、**把 task id 当台账编号连错两次**(#176/#174 已按 md 重建)。
- **默认不变**：包里仍是 rc73 `34b3efa8…`；#178(当前版包认证)顺延第 53 发；#185 的 A/B 只管"回收后能不能自己回亮"，不是"灭"的解。
- **机器现态**：`Enforcing`、`mod=0`、boot_id `ccde849f`、**10-24 枪数＝2**；今晚不再打，第 52 发等下一个自然窗且要用户点头。

"""


def insert_before_heading(path, needle, block, mark, label):
    s = rd(path)
    if mark in s:
        print("  [skip] %s 已有这一节 ⇒ 幂等不重复插" % label)
        return
    if s.count(needle) != 1:
        print("[x] %s 锚 %s 命中 %d(要 1) ⇒ 不写" % (label, needle[:40], s.count(needle)))
        sys.exit(1)
    pos = s.rfind("\n## ", 0, s.find(needle))
    if pos < 0:
        print("[x] %s 锚上面找不到 `## ` 标题行 ⇒ 不写" % label)
        sys.exit(1)
    wr(path, s[:pos + 1] + block + s[pos + 1:])
    print("  [插入] %s 新节写在偏移 %d" % (label, pos + 1))


print("=== w735 文档同步(第 52 发备妥) ===")
snap = {}
for path, old, new, want in DEPAIR:
    s = snap.get(path, rd(path))
    got = s.count(old)
    snap[path] = s
    print("  [拆等号] %s 命中=%d(期望 %d)" % (os.path.basename(path), got, want))
    if got != want:
        print("[x] 锚不符 ⇒ 全部不写")
        sys.exit(1)
for path, old, new, want in DEPAIR:
    snap[path] = snap[path].replace(old, new)
for path in snap:
    wr(path, snap[path])

insert_before_heading(CH, "2026-10-24 16:1x–17:3x 第 51 发(1 枪)", NEW_CH, "19:3x–19:5x 收口：0 枪：第 52 发的形状与仪器", "CONTINUE_HERE.md")
insert_before_heading(CS, "2026-10-24 17:4x 更新", NEW_CS, "19:5x 更新（本节最新", "CURRENT-STATUS.md")
# 上一节的"本节最新"声明要撤下来，否则文档里同时有两节自称最新
cs = rd(CS)
old_claim = "2026-10-24 17:4x 更新（本节最新，取代 15:4x 那节）"
if cs.count(old_claim) == 1:
    wr(CS, cs.replace(old_claim, "2026-10-24 17:4x 更新（已被 19:5x 那节取代）"))
    print("  [撤声明] CURRENT-STATUS 17:4x 那节的『本节最新』已撤下")
else:
    print("  [i] 17:4x 那节的声明命中 %d(可能早已撤过) ⇒ 不动" % cs.count(old_claim))

print("  写完后哈希：CONTINUE=%s CURRENT=%s" % (md5(CH), md5(CS)))
print("  ★最后一步：跑 w415 期望命中 0；跑 w413 期望 rc=0")
print("=== w735 完成 ===")
