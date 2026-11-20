#!/usr/bin/env bash
# w1231 — ftrace 抓取 sucompat/allow_uid 致死窗（cut=5 ko 必 ~19.5 s 硬复位）
# 用法：w1231_ftrace_capture.sh <SN> <OUT_DIR> [DURATION_S]
# 责任：insmod 之前设局；之后每 1 s 抓 /sys/kernel/tracing/trace 快照（环形缓冲＝死前最后一瞬）。
# 不负责 insmod——insmod 由 go.sh 另行触发（本脚本与 go.sh 并发跑）。
set -u
SN="${1:?usage: w1231 <SN> <OUT_DIR> [DURATION_S]}"
OUT="${2:?usage: w1231 <SN> <OUT_DIR> [DURATION_S]}"
DUR="${3:-22}"
TRC="/sys/kernel/tracing"
ADB="C:/adb/platform-tools/adb.exe -s $SN"
mkdir -p "$OUT"

# --- 0. tracefs 路径探测（部分内核在 debugfs） ---
if ! $ADB shell "test -d $TRC" 2>/dev/null; then
  TRC="/sys/kernel/debug/tracing"
  echo "[w1231] tracefs 改走 $TRC"
fi

# --- 1. 设局（tracing_on=0 下写，避免边写边跑） ---
echo "[w1231] 设局 ftrace ..."
$ADB shell "cd $TRC && echo 0 > tracing_on && echo nop > current_tracer" 2>/dev/null
$ADB shell "cd $TRC && echo function_graph > current_tracer" 2>/dev/null
$ADB shell "cd $TRC && echo 1 > max_graph_depth" 2>/dev/null
# 只盯 3 个函数（名字全局唯一，无需 :mod:）
$ADB shell "cd $TRC && echo '__ksu_is_allow_uid_for_current __ksu_is_allow_uid ksu_handle_execve_sucompat_common' > set_ftrace_filter" 2>/dev/null
# 尽量放大缓冲（失败不致命，用默认 1410 KB）
$ADB shell "cd $TRC && (echo 8192 > buffer_size_kb || echo 4096 > buffer_size_kb || true)" 2>/dev/null
$ADB shell "cd $TRC && echo > trace && echo 1 > tracing_on" 2>/dev/null
echo "[w1231] tracing_on=1; 现在可另开终端跑 go.sh 装载 cut=5 ko"

# --- 2. 抓取循环 ---
TAG="$(date +%H%M%S)"
echo "[w1231] 抓取 $DUR s，每 1 s 一拍 → $OUT/ftrace_shot_*.txt"
i=0
while [ "$i" -lt "$DUR" ]; do
  TS="$(date +%H%M%S.%03N)"
  if ! $ADB shell "cd $TRC && cat trace" > "$OUT/ftrace_shot_${TAG}_${i}_${TS}.txt" 2>/dev/null; then
    echo "[w1231] @${TS} adb 掉线 ⇒ 设备硬复位（cut=5 致死窗结束）。停止抓取。"
    echo "RESET_DETECTED $TS" > "$OUT/ftrace_RESET_${TAG}.txt"
    break
  fi
  sz=$(wc -c < "$OUT/ftrace_shot_${TAG}_${i}_${TS}.txt" 2>/dev/null || echo 0)
  echo "[w1231] shot $i @$TS size=$sz"
  i=$((i+1))
  sleep 1
done

# --- 3. 收尾（设备若还活着才做；掉了就算了） ---
$ADB shell "cd $TRC && echo 0 > tracing_on && echo nop > current_tracer" 2>/dev/null || true
echo "[w1231] 完毕。快照：$OUT/ftrace_shot_${TAG}_*.txt"
