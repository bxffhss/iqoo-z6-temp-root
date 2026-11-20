#!/usr/bin/env bash
# 第 27 发的跟随器：120 格 × 25 秒 ≈ 50 分钟，每格一行 up/mod/enf/suw/termux/bid。
#   主判据是 boot_id(例 101：撞进被测流程自己的复位是计划内状态)；判活线在拿到 insmod 落点后现算＝落点+1800。
export MSYS_NO_PATHCONV=1
i=0
while [ $i -lt 120 ]; do
    i=$((i+1))
    R=$(adb shell 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) suw=$(pidof com.suw.manager) tmx=$(pidof com.termux) bid=$(cat /proc/sys/kernel/random/boot_id)' 2>/dev/null | tr -d '\r')
    echo "[$(date +%H:%M:%S)] $R"
    sleep 25
done
echo "[$(date +%H:%M:%S)] WATCH_DONE rows=$i"
