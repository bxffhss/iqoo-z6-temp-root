#!/bin/bash
# w1214 —— Exp-8(串行闸) PC 侧独立时间轴（第 15 枪）
#   为什么独立：设备侧 w184_sample.out 写在 /data/local/tmp，崩溃后可能读不回来；
#   外部采样只看 up=/boot_id/mod=/enf=，判"这一 boot 什么时候没的"，不依赖设备还活着。
#   5 s/行（w1210 计划原文要求），40 min = 480 拍，覆盖主判据"存活≥30 min"并留裕量。
#   ★只读探针：一次 adb shell 只跑 sh+cut+cat+grep，<1 execve/s，相对 727/s 的风暴可忽略。
set -u
cd "$(dirname "$0")/.." || exit 1
ADB="C:/adb/platform-tools/adb.exe -s <DEVICE_SERIAL>"
OUT=kmod/w103_evidence/exp8_pc_timeline.txt
: > "$OUT"
echo "# exp8 PC timeline start $(date '+%F %T')  (5s/tick, 480 ticks)" >> "$OUT"
i=0
while [ "$i" -lt 480 ]; do
    TS=$(date '+%F %T')
    # ★$ADB 不能加引号：加了就变成"一整个字符串当命令名"⇒ 每拍都 OFFLINE（自证过一次）
    L=$($ADB shell 'echo "up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c "^kernelsu " /proc/modules 2>/dev/null) enf=$(getenforce 2>/dev/null) boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8) ksud=$(ls /dev/ksud >/dev/null 2>&1 && echo 1 || echo 0)"' 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    [ -z "$L" ] && L="OFFLINE"
    echo "$TS  $L" >> "$OUT"
    i=$((i+1))
    sleep 5
done
echo "# exp8 PC timeline end $(date '+%F %T')" >> "$OUT"
