#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w769_docsync11.py —— 第 53 发跑完之后把"交付默认升到 rc74b 包"这件事落到三份文档（含新增的两条使用口径）。
   跑法：PYTHONUTF8=1 python kmod/w769_docsync11.py
   ★两阶段核锚(先全局核完再统一写)＋幂等(已做过就跳过)——这条是 §6.422 认账的规矩。
"""
import hashlib
import io
import os
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DL = os.path.join(R, "kmod", "DELIVERY.md")
CH = os.path.join(R, "analysis", "CONTINUE_HERE.md")
CS = os.path.join(R, "analysis", "CURRENT-STATUS.md")
LB = os.path.join(R, "kmod", "ROUTE-B-OFFSET-INVERSION.md")
GATE = "6f7fef11"     # 总闸现值(注册完 w767/w769 之后现取)


def md5(p):
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()[:8]


def rd(p):
    return io.open(p, encoding="utf-8", errors="surrogateescape").read()


def wr(p, s):
    io.open(p, "w", encoding="utf-8", newline="", errors="surrogateescape").write(s)


PLAN = md5(os.path.join(R, "kmod", "w760_shot53_plan.md"))
ZKO = md5(os.path.join(R, "z6root", "kernelsu.ko"))

# ---------- 1) 台账 ----------
LB_ADD = (u"""
## §6.423 —— 10-24 23:15–00:12（**第 53 发＝1 枪**）：**当前版包（包内 ko＝rc74b）设备侧一条命令认证过＝交付默认升到 rc74b**；★同发抓到两枚实名：`Fatal signal 31 (SIGSYS) syscall 142 in (libksud.so)`（旧推断升为有实名行）与 **`SU4 after nested execveat: ret=0 uid=10667`**（app 侧 su 改道 fire 的内核侧证人）；★另抓到一条流程事实：**B 形状下 PC 侧 root 通道是瞎的**
- **形状**：被测＝包本身（`/system/bin/sh /sdcard/z6root/z6root.sh`，**不走 PC 编排**）；包内 ko＝`18750560…`(5,106,064 B)、args 五条未动、`z6root.zip`＝`af5fff6c…`；判据十格开枪前写死＝`kmod/w760_shot53_plan.md`(现值 `""" + PLAN + u"""`，含读数)。旧包（第 33 发认证那份，ko＝rc73）整目录留在 `/sdcard/z6root_shot33_rc73` **没覆盖**。
- **甲组（#178 七条）**：①入口证人（`入口形状=1`、`[10667 com.termux] 词数=2 字节=17`）②实参原文＋三条三证 ③活表 `count=1 uid=10667 granted=1` ④载荷两端各核（包 21 条 ok ＋我 22 件逐字对）⑦`Z6ROOT_DONE up=7200.16 mod=1 enforce=Permissive`——**五条直接成立**；`slide=0000002bda800000` 设备侧自解、`NOSUW_BIND_RC=0 HEALTH=OK`。
  ★**两条如实降级**：**⑤"屏幕出现 uid=0"未拿到**（第一次打字腿失败：Termux 不在前台＋InputManager 异常；#116 那格本来就挡着），改用两条独立证人替代：内核侧 `SU0→SD4→SU1b/c/d→SU3→**SU4 ret=0 uid=10667**` ＋ 那条 su 跑起来的脚本自报 `uid=0`；**⑥包里那条 `w450_close.sh` 没跑**，等价动作由 `kmod/w767_close_shot53.sh` 经 Termux 的 su 完成（`/data/adb [ksu ksud]`→`[]`、151 条清理件、补删、最后 `enforce=1`）。
- **乙组（#184）＝第二次未复现，而且方向变了**：新 Manager `pid=32050`（`start_ticks=719398`＝insmod 后 19.9 秒出生）从 up=7441 到 8047 全程 `工作中／32601-2／越狱`；**三次"进超级用户页停 10 秒→回首页"读数一字不差**（`字节=18500 节点=20`），`不支持` **0 次**；`fd_ksu=`**1**（这发没有第二个生产者）、`dupskip n`→**133633**、`cap`真踢=0、`signal 6`=0、`Seccomp=2`。
  ★**实名行抓到**：`Fatal signal 31 (SIGSYS), code 1 (SYS_SECCOMP), syscall 142 in … (libksud.so)` ×3（backtrace 帧全在 `…/me.weishu.kernelsu-…/lib/arm64/libksud.so`）⇒ **#125 那条从"推断"升为"有实名行"**，但**死的是 `libksud.so` 自己的进程，主进程活着、牌子不掉** ⇒ (c) 与牌子无关、(a) 在 rc74b 下不成立、(b) 未观测。
  ⇒ **对用户症状的新解释**：他那一次跑的很可能是**上一份包（rc73）**——那里进程一被系统回收就再没人补装 fd，"点返回"只是让画面重绘出新状态；这条现在有三发正面凭据（51/52/53 都是"新进程必有 fd、不掉"）。**#184 因此改形状**：不再自己开枪追"什么操作让它灭"，改成**用户真复现时当场抓 logcat**（我们这边已把三件读数做成一条腿）。
- ★**流程发现（交付口径要写）**：**B 形状（名单只写目标 app）下 suw 未被授权 ⇒ PC 侧 `@sushd:`/`rleg` 这条 root 通道整条是瞎的**——`w731 … 没等到 DONE` 只是表象，真凭据是"设备上连 `.out` 都没生成"。⇒ **走 B 形状时收尾必须在目标 app 里用 `/system/bin/su -c <腿>`**（包里那条 `w450_close.sh` 就是干这个的，教程第 7 步）。另一条：**打字腿要先确认 `mCurrentFocus=com.termux` 且暖一行**（补上之后同一条命令一次成功）。
- ★**我自己的一个缺陷（第三次犯同一条）**：判据 2 的"起点 vNN stage=…"那行只活在 `/data/local/tmp/ksu_stage.log`，而我在补删里把它删了 ⇒ **不可恢复**。⇒ 规矩重申：**补删之前先 pull 存证**（这条在 §6.369/#137 那族已经认过两次）。
- **件与闸（现取）**：出货候选→**已认证**：`z6root/kernelsu.ko`＝`""" + ZKO + u"""…`；打字收尾腿 `kmod/w767_close_shot53.sh`＝`5ef047d5`（设备副本同 md5、`sh -n` 过）；存证 `w761_pkg_run_shot53.log`(PKG_RC=0)、`w762_mgr_home_shot53.xml`、`w763_sup1..6.xml`、`w765_c1..3a_home.xml`/`w765_final_home.xml`、`w764/w766_crash_*.txt`、`w768_close_shot53.txt`；总闸 `kmod/w413_selftest_sweep.sh`＝`""" + GATE + u"""`；文档同步 `kmod/w769_docsync11.py`；`w415` 命中 **0**。
- **机器现态**：`Enforcing`、`mod=0`、`/product/bin` 挂载=0、boot_id `62aac196`、**10-24 枪数＝4**；`hist` 最新＝`cold,charger,1792856771`（★我们敲的是 `adb reboot`，这台机仍会记成 `cold,charger`——"分不了收尾 vs 异常复位"第四次兑现，别拿 bootreason 当结论）。
""")

# ---------- 2) DELIVERY：把"候选/未认证"升成"已认证" ----------
DL_REPS = [
    (DL,
     u"★**候选出货 ko**",
     u"★**出货 ko（第 53 发已认证＝交付默认）**", 1),
    (DL,
     u"第 51/52 发两发判正；**尚未过 #178 包认证 ⇒ 对外还不能当交付**)",
     u"第 51/52/53 发三发判正；**10-24 23:29–00:12 第 53 发以「设备侧一条命令」认证过 ⇒ 它就是交付默认(旧版留仓可回退)**)", 1),
    (DL,
     u"｜**最后一份认证过的出货 ko** ",
     u"|**上一版出货 ko（留仓可回退）** ", 0),
]

NEW_CH = (u"## ★★★★★★★★★★★★★★★★★★ **2026-10-24 23:15–00:12 第 53 发(1 枪)：当前版包（包内 ko＝rc74b）设备侧一条命令认证过 ⇒ 交付默认升到 rc74b**；"
          u"★同发抓到两枚实名（`SIGSYS syscall 142 in libksud.so` 与 `SU4 nested execveat ret=0 uid=10667`）＋一条流程事实（**B 形状下 PC 侧 root 通道整条是瞎的**）\n\n"
          u"- **甲组七条**：五条直接成立（入口证人/实参原文/活表 `count=1 uid=10667 granted=1`/载荷两端各核/`Z6ROOT_DONE`），`slide=0000002bda800000` 设备侧自解；"
          u"**两条如实降级**：⑤\"屏幕出现 uid=0\"未拿到（第一次打字腿失败＝Termux 不在前台），改由 `SU4 … ret=0 uid=10667` ＋ 脚本自报 `uid=0` 两条替代证人；"
          u"⑥包里那条 `w450_close.sh` 没跑，等价动作由 `kmod/w767_close_shot53.sh` 经 Termux 的 su 完成（`/data/adb`→`[]`、151 条、`enforce=1` 在最后）。\n"
          u"- **乙组＝第二次未复现**：新 Manager（pid 32050，insmod 后 19.9 秒出生）从 up=7441 到 8047 全程 `工作中／32601-2／越狱`，"
          u"三次\"进超级用户页停 10 秒→回首页\"读数**一字不差**、`不支持` 0 次；`fd_ksu`＝**1**、`dupskip n`→**133633**、`cap`真踢=0、`signal 6`=0。"
          u"★实名行抓到了：`Fatal signal 31 (SIGSYS), syscall 142 in (libksud.so)` ×3 ⇒ #125 那条升为有凭据，**但死的是 libksud.so 自己，主进程活着、牌子不掉** ⇒ (c) 与牌子无关。\n"
          u"- ⇒ **对用户\"牌子会灭\"的新解释**：他那次跑的应是**上一份包（rc73）**——进程被回收后没人补装 fd，\"点返回\"只是重绘；这条有三发正面凭据。"
          u"**#184 改形状**：不再自己开枪追，改成用户真复现时当场抓 logcat（三件读数已做成一条腿）。**#185 的 A/B 继续挂着**、**#110 继续关着**（现在有了\"它不影响牌子\"的一手）。\n"
          u"- **两条要写进口径的操作事实**：①**B 形状下 PC 侧 root 腿全瞎**（suw 未授权）⇒ 收尾要在目标 app 里 `/system/bin/su -c <腿>`；"
          u"②打字腿必须先确认 `mCurrentFocus` 是目标 app 且暖一行（补上后同一条命令一次成功）。\n"
          u"- **登记(现取)**：判据＋读数 `kmod/w760_shot53_plan.md`＝`" + PLAN + u"…`｜包内 ko `z6root/kernelsu.ko`＝`" + ZKO + u"…`｜打字收尾腿 `kmod/w767_close_shot53.sh`＝`5ef047d5…`｜旧包备份留在设备 `/sdcard/z6root_shot33_rc73`（没覆盖）｜"
          u"总闸 `kmod/w413_selftest_sweep.sh`＝`" + GATE + u"…`（rc=0，含 `run_w731`）｜`w415` 命中 **0**。\n"
          u"- **机器现态**：`Enforcing`、`mod=0`、boot_id `62aac196`、**10-24 枪数＝4**；★`hist` 最新一条是我们自己 `adb reboot` 却记成 `cold,charger`——bootreason 第四次分不清，别当结论。\n\n")

NEW_CS = (u"## ★★★★★★★★★★★★★★★★★★ 2026-10-25 00:2x 更新（本节最新，取代 22:4x 那节）—— **第 53 发(1 枪)：当前版包认证过 ⇒ 出货默认＝rc74b 包；\"牌子会灭\"这次抓到实名但**没复现**\n\n"
          u"- 甲组七条：5 条直证 ＋ ⑤⑥ 两条降级（屏幕那格改由内核 `SU4 … ret=0 uid=10667` 与脚本 `uid=0` 替代；包里 `w450_close` 未跑，改自写腿经 Termux su 完成，`/data/adb`→`[]`、`enforce=1`）。\n"
          u"- 乙组：pid 32050 全程 `工作中／32601-2／越狱`，三次进超级用户页停 10 秒后读数一字不差、`不支持` 0 次；`fd_ksu`=1、`dupskip n`→133633、`cap`/`signal 6` 全 0。\n"
          u"- ★实名：`Fatal signal 31 (SIGSYS), syscall 142 in (libksud.so)` ×3 ⇒ 官方 ksud 那支确被 app 域 seccomp 打死，**但不影响主进程与牌子** ⇒ (c) 出局、(a) 在 rc74b 下不成立、(b) 未观测。\n"
          u"- ⇒ **默认升到 rc74b**（`z6root/kernelsu.ko`＝`" + ZKO + u"…`，第 51/52/53 三发凭据）；**#185 A/B 与 #110 继续挂着/关着**；#184 改成\"用户复现时当场抓 logcat\"。\n"
          u"- 现值：判据＋读数 `kmod/w760_shot53_plan.md`＝`" + PLAN + u"…`｜`kmod/w767_close_shot53.sh`＝`5ef047d5…`｜总闸 `kmod/w413_selftest_sweep.sh`＝`" + GATE + u"…`（rc=0）｜`w415` 命中 0｜机器 `Enforcing mod=0`、boot_id `62aac196`、枪数 4。\n\n")


def core_and_write(reps):
    src, acts = {}, []
    for path, old, new, want in reps:
        s = src.get(path, rd(path))
        src[path] = s
        go, gn = s.count(old), s.count(new)
        if go == want:
            acts.append((path, old, new))
            print("  待做 %s：%s" % (os.path.basename(path), old[:40]))
        elif gn == want:
            print("  已做过(跳过) %s：%s" % (os.path.basename(path), new[:40]))
        else:
            print("[x] %s 既非待做也非已做(old=%d new=%d 期望%d)：%s ⇒ 全部不写"
                  % (os.path.basename(path), go, gn, want, old[:40]))
            sys.exit(1)
    for path, old, new in acts:
        src[path] = src[path].replace(old, new)
    for path in src:
        wr(path, src[path])
    print("  写了 %d 处" % len(acts))


print("=== w769 文档同步(第 53 发：升默认已认证) ===")
if u"## §6.423" not in rd(LB):
    with io.open(LB, "a", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(LB_ADD)
    print("  台账 §6.423 已追加")
else:
    print("  台账 §6.423 已存在(跳过)")

core_and_write(DL_REPS)


def insert(path, needle, block, mark, label, declaim=None):
    s = rd(path)
    if mark in s:
        print("  [skip] %s 已有这节" % label)
    else:
        if s.count(needle) != 1:
            print("[x] %s 插入锚命中 %d(要1) ⇒ 不写" % (label, s.count(needle)))
            sys.exit(1)
        pos = s.rfind("\n## ", 0, s.find(needle))
        assert pos >= 0, label
        s = s[:pos + 1] + block + s[pos + 1:]
        print("  [插入] %s 偏移 %d" % (label, pos + 1))
    if declaim and s.count(declaim[0]) == 1:
        s = s.replace(declaim[0], declaim[1])
        print("  [撤声明] %s" % label)
    wr(path, s)


insert(CH, u"2026-10-24 20:32–21:33 第 52 发", NEW_CH, u"23:15–00:12 第 53 发(1 枪)", "CONTINUE_HERE.md")
insert(CS, u"2026-10-24 22:4x 更新", NEW_CS, u"2026-10-25 00:2x 更新", "CURRENT-STATUS.md",
       declaim=(u"2026-10-24 22:4x 更新（本节最新，取代 21:4x 那节）", u"2026-10-24 22:4x 更新（已被 00:2x 那节取代）"))

print("  写完：DELIVERY=%s CONTINUE=%s CURRENT=%s 台账=%s" % (md5(DL), md5(CH), md5(CS), md5(LB)))
print("=== w769 完成 ===")
