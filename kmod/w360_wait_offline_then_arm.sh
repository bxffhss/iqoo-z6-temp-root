#!/usr/bin/env bash
# 用法：bash kmod/w360_wait_offline_then_arm.sh <存证名> [采样次数=2400]
# 为什么需要它(例 95 的第二半)：w360_arm_newboot.sh 的前提是"调用方一手见过掉线"。
#   如果我在设备还在线的时候就把它后台起来，它会立刻 adb devices 抓到在线 ⇒ 要么误退(闸起作用)，
#   要么靠 I_SAW_IT_OFFLINE=1 把闸跳过(那前提就得由我提供证据)。这条包装腿负责**当场生产那条证据**：
#   一直轮询到第一次"掉线"，把时刻写进存证，再把 arm 腿带 override 起来。
set -u
export MSYS_NO_PATHCONV=1
TAG=${1:-t0}
N=${2:-2400}
OUT="kmod/w103_evidence/w360_waitoffline_${TAG}.txt"
echo "包装腿起 $(date '+%F %T') 计划=最多轮询 240 次(每 5 秒 ⇒ 20 分钟) 采样次数=$N" | tee "$OUT"
GOT=0
for i in $(seq 1 240); do
    LV=$(timeout 20 adb devices 2>/dev/null | tr -d '\r' | grep -cw device)
    if [ "$LV" = 0 ]; then
        echo "第 $i 次轮询：★第一次抓到**掉线** $(date '+%F %T') ⇒ 下一次在线就是**新 boot**(这条就是 arm 腿要的前提)" | tee -a "$OUT"
        GOT=1
        break
    fi
    [ $((i % 20)) -eq 0 ] && echo "  第 $i 次：仍在线(在线数=$LV) $(date '+%T')" | tee -a "$OUT"
    sleep 5
done
if [ "$GOT" != 1 ]; then
    echo "[x] 轮询满 20 分钟没见过掉线 ⇒ 停(说明开窗那条腿没 reboot，或它比我先跑完了)。★不要手工补 override。" | tee -a "$OUT"
    exit 6
fi
sleep 3
echo "----- 交给 w360_arm_newboot.sh(带 override，前提证据就在本文件上面几行) -----" | tee -a "$OUT"
I_SAW_IT_OFFLINE=1 bash kmod/w360_arm_newboot.sh "$N" 2>&1 | tee -a "$OUT"
