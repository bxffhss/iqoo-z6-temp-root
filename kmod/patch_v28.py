#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v27 -> v28 两处修正（md §6.60）：
   ① 判据①在 insmod 刚返回时**总是 grep 到空**（活落盘是 dd 逐条异步写的）⇒ 先 sleep 再读，
      还空就从 dmesg 兜一次；
   ② 我自己造的 execve 风暴（逐线程 3 个 grep × 每 3s 一轮 × PC 侧 25 轮 ≈ 数千次 fork，
      而 rc27 的 KSUBEAT F 对每次 execve 都打一行）⇒ 改成一条 glob + 一次 grep，外层降频。
   顺带把驱动器"起点行"的版本判断放宽成前缀（真正判"本 boot"靠 uptime 差）。
"""
import io
import sys

POST = "kmod/ksu_one_stage.sh"
DRIVER = "kmod/run_app_window.sh"

HEAD_OLD = "# ksu_one_stage.sh v27 —— 一个 boot 只试一档；这一档只剩一个目标(md §6.59)：\n"
HEAD_NEW = (
    "# ksu_one_stage.sh v28 —— v27 的两处修正(md §6.60)，目标不变：\n"
    "#   ① 判据①(insmod 一返回就 grep 活落盘)本机**总是空**：dumper 是 dd 逐条异步写，\n"
    "#      那些行还没落文件 ⇒ 第三十六发里 P1/P2/A readback 整段没印出来，而事后 dmesg 全在。\n"
    "#      ⇒ 现在先 sleep 2 再读，仍空就从 dmesg 兜一次(同一判据，换来源)。\n"
    "#   ② 自己造的 execve 风暴：catch_root_thread 每线程起 3 个 grep、外层每 3s 一轮，\n"
    "#      再加 PC 侧驱动器同样扫法 25 轮 ⇒ 数千次 fork，而 rc27 的 KSUBEAT F 对**每次 execve**\n"
    "#      都打一行；第三十六发脚本跑完 ~1.5 分钟后机器复位(当时正在跑那些扫描)。\n"
    "#      ⇒ 现在一条 glob + 一次 grep，后处理降到每 4 轮(≈12s)，PC 侧只扫 3 轮。\n"
    + HEAD_OLD
)

SCAN_OLD = """catch_root_thread() {
    P="$1"
    [ -n "$P" ] || return 0
    for st in /proc/$P/task/*/status; do
        [ -f "$st" ] || continue
        U=$(grep -m1 '^Uid:' "$st" | awk '{print $2}')
        if [ "$U" = "0" ]; then
            log "  ★外部证据: $st -> $(grep -m1 '^Uid:' "$st" | tr -d '\\n') | $(grep -m1 '^CapEff:' "$st" | tr -d '\\n')"
        fi
    done
    return 0
}
"""
SCAN_NEW = """catch_root_thread() {
    P="$1"
    [ -n "$P" ] || return 0
    U=$(grep -h '^Uid:' /proc/$P/task/* 2>/dev/null)
    [ -n "$U" ] || return 0
    H=$(printf '%s\\n' "$U" | grep -c $'^Uid:\\t0\\t')
    [ "$H" = "0" ] && return 0
    log "  ★外部证据: app pid=$P 有 $H 个线程 Uid=0: $(printf '%s\\n' "$U" | grep $'^Uid:\\t0\\t' | tr '\\n' '|')"
    return 0
}
"""

J1_OLD = """log "===== 判据①：sys_call_table 那笔写 ====="
grep -E 'KSUBEAT (P1|P2|P3|P4|A )|patch syscall|registered syscall hook|sys_enter tracepoint|mark-running' "$LIVE" | tail -14
"""
J1_NEW = """log "===== 判据①：sys_call_table 那笔写 ====="
# ★v28：活落盘是 dd 逐条**异步**写的，insmod 一返回就去 grep 必然什么都没有(v27 就是空的)
sleep 2
grep -E 'KSUBEAT (P1|P2|P3|P4|A )|patch syscall|registered syscall hook|sys_enter tracepoint|mark-running' "$LIVE" | tail -14
N1=$(grep -c 'KSUBEAT A ' "$LIVE" 2>/dev/null)
if [ "$N1" = "0" ]; then
    log "  活落盘还没跟上 ⇒ 直接从 dmesg 兜一次(同一判据，另一个来源)"
    dmesg 2>/dev/null | grep -E 'KSUBEAT (P1|P2|P4|A )|patch syscall|reboot kprobe registered' | tail -10
fi
"""

LOOP_OLD = """        APP_PID=$(pidof $PKG | cut -d' ' -f1)
        catch_root_thread "$APP_PID"
        i=$((i + 1))
        sleep 3
"""
LOOP_NEW = """        if [ $((i % 4)) = "0" ]; then           # ★每 4 轮(≈12s)一次，别自己造 execve 风暴
            APP_PID=$(pidof $PKG | cut -d' ' -f1)
            catch_root_thread "$APP_PID"
        fi
        i=$((i + 1))
        sleep 3
"""

DR_OLD = '    case "$FIRST" in *"起点 v27"*) ;; *) return 1;; esac\n'
DR_NEW = '    case "$FIRST" in *"起点 v2"*) ;; *) return 1;; esac   # 前缀就够，真正判"本 boot"靠下面的 uptime 差\n'


def patch(path, pairs):
    s = io.open(path, encoding="utf-8", errors="replace").read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            print("!! %s: 锚点命中 %d 次 -> %r" % (path, n, old[:60]))
            sys.exit(1)
        s = s.replace(old, new)
    io.open(path, "w", encoding="utf-8", newline="\n").write(s)
    print("已改 %s" % path)


patch(POST, [(HEAD_OLD, HEAD_NEW),
             ('log "=== 起点 v27 stage=$S', 'log "=== 起点 v28 stage=$S'),
             (J1_OLD, J1_NEW)])
patch(DRIVER, [(DR_OLD, DR_NEW)])
# 注: catch_root_thread 的省 fork 改法与"每 4 轮一次"已经用唯一锚点单独改好了，这里不再重复。
