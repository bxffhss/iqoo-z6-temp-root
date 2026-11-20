# -*- coding: utf-8 -*-
"""patch_stage_mgrshell.py —— 让 stage 用 **shell 域**起官方 Manager，并轮询等 pid 再装驱动 fd。

第 32 发的一手事实：stage 以 root 跑，而 root 域 `am start` 报
`cmd: Can't find service: activity`（vivo 对非 shell 域隐藏服务列表，与 Z5 教程记的
"root 域 `service list` 看到 0 个服务"是同一条）。⇒ stage 里 `MPID` 一直是空 ⇒
`/proc/ksu_install_fd` 从没被写过 ⇒ 官方 Manager 拿不到驱动 fd ⇒ 首页永远"不支持"，
和"加冕成没成"根本无关。

正解：`runcon u:r:shell:s0 am start` 起它（保留原来那条做兜底），并且**轮询等 pid**
——这样 PC 侧把 app 起来的也算，谁先起来都能装上 fd。
"""
import io
import sys

NL = chr(10)
SQ = chr(39)
D = chr(34)

P = "kmod/ksu_one_stage.sh"
s = io.open(P, encoding="utf-8").read()

if "runcon u:r:shell:s0 am start" in s:
    print("stage 已经改过 ⇒ 跳过")
    sys.exit(0)

ANCHOR = (
    "    am start -n $MGRPKG/.ui.MainActivity >/dev/null 2>&1" + NL
    + "    sleep 4" + NL
    + "    MPID=$(pidof $MGRPKG | cut -d" + SQ + " " + SQ + " -f1)"
)
if s.count(ANCHOR) != 1:
    sys.exit("ANCHOR count=%d" % s.count(ANCHOR))

NEW = (
    "    # ★第 32 发：root 域 `am start` 会报 `Can't find service: activity`(vivo 对非 shell 域隐藏服务)" + NL
    +"    #   ⇒ MPID 一直是空 ⇒ /proc/ksu_install_fd 从没被写过 ⇒ Manager 拿不到驱动 fd ⇒ 首页永远" + D + "不支持" + D + "。" + NL
    +"    #   正解：换 shell 域起它(原来那条留作兜底)，再**轮询等 pid**——PC 侧起来的也算。" + NL
    +"    runcon u:r:shell:s0 am start -n $MGRPKG/.ui.MainActivity >/dev/null 2>&1" + NL
    +"    am start -n $MGRPKG/.ui.MainActivity >/dev/null 2>&1" + NL
    +"    MPID=" + SQ + SQ + NL
    +"    for q in $(seq 1 40); do" + NL
    +"        sleep 3" + NL
    +"        MPID=$(pidof $MGRPKG | cut -d" + SQ + " " + SQ + " -f1)" + NL
    +"        [ -n " + D + "$MPID" + D + " ] && { log " + D + "      轮询 $((q*3))s 后拿到 Manager pid=$MPID" + D + "; break; }" + NL
    +"    done" + NL
    +"    [ -n " + D + "$MPID" + D + " ] || log " + D + "      !! 等满 120s 仍没有 Manager 进程 ⇒ fd 装不上，这一格不算" + D
)

io.open(P, "w", encoding="utf-8", newline="").write(s.replace(ANCHOR, NEW))
print("ok 已改 stage：shell 域起 Manager + 轮询等 pid")
