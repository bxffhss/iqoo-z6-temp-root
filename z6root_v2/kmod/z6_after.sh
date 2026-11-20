#!/bin/bash
# z6_after.sh — 软重启后恢复：确保 shd(idle=0) + 主动重抢装管理器 + 维持件
#   通常 z6_soft 后 shd/维持件已自动扛过；本脚本用于"没自动回"时手动补一次。
#   ★前提：@sushd(root 腿)还活着才能派单；若已死，本脚本只能报告现状（此时可靠维持件自己）。
#   轻量不装模块：只恢复 root+su+越狱模式；LSPosed 要另跑 z6_on.sh（默认档）。
set -u
export MSYS_NO_PATHCONV=1
export PATH="/c/adb/platform-tools:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 1
[ -f config.sh ] && . ./config.sh   # 可选：预设 DEV（多设备时）
ADB="${ADB:-adb}"; A(){ "$ADB" "$@"; }
ap(){ A shell "$1" 2>/dev/null | tr -d '\r'; }

echo "==== z6_after  软重启后恢复 ===="
MOD=$(ap "grep -c kernelsu /proc/modules"); MOD=${MOD:-0}
[ "$MOD" = "1" ] || { echo "[x] 没有活窗口(mod=$MOD)（软重启后 ko 竟没在？）⇒ 只能 bash kmod/z6_on.sh 重开"; exit 3; }
echo "  现状: shd=$(ap 'pidof shd') keeper=$(ap "ps -A -o PID,ARGS 2>/dev/null | grep -a 'b8_keep.sh RUN' | grep -av grep | awk '{print \$1}'") mgr=$(ap 'pidof me.weishu.kernelsu')"

# 确保 z6_light.sh 在设备
ap "test -x /data/local/tmp/z6_light.sh && echo ok" | grep -q ok || A push kmod/z6_light.sh /data/local/tmp/z6_light.sh >/dev/null 2>&1
A push kmod/b8_keep.sh /data/local/tmp/b8_keep.sh >/dev/null 2>&1

echo "  派单 z6_light（shd + 主动抢装 + 维持件）"
A shell "am force-stop com.suw.manager" >/dev/null 2>&1; sleep 1
A shell "am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd '@sushd:/data/local/tmp/z6_light.sh'" >/dev/null 2>&1
for i in $(seq 1 30); do ap "grep -aq '===== DONE' /data/local/tmp/z6_light.log && echo done" | grep -q done && break; sleep 3; done
ap "grep -aE 'SHD=|MGR=|KEEPER' /data/local/tmp/z6_light.log" 2>/dev/null

echo "  之后: shd=$(ap 'pidof shd') mgr=$(ap 'pidof me.weishu.kernelsu')"
echo "  若 mgr 在跑但显示不支持：管理器被重开但没抢上 ⇒ 再跑一次本脚本；仍不行就 bash kmod/z6_on.sh --no-modules 重开"
