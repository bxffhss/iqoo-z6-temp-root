#!/bin/bash
# w424 —— Exp-6b 外部生存采样(独立于 go.sh 的设备侧采样器)
#   为什么要独立一支：设备侧 w184_sample.out 写在 /data/local/tmp，崩溃后可能读不回来；
#   外部采样从 PC 侧看 up=/boot_id，能给出「这一 boot 什么时候没的」而不依赖设备还活着。
#   节流到 10s 一次：exp6 那发设备侧已经在 3s 采样，外部这支只负责兜底判 reboot，别跟 go.sh 抢 adb。
set -u
cd "$(dirname "$0")/.." || exit 1
ADB="/c/adb/platform-tools/adb.exe -s <DEVICE_SERIAL>"
OUT=kmod/w103_evidence/exp6b_local_timeline.txt
: > "$OUT"
echo "# exp6b timeline start $(date '+%F %T')  (10s/tick)" >> "$OUT"
i=0
while [ "$i" -lt 120 ]; do   # 120*10s = 20 分钟
    TS=$(date '+%F %T')
    L=$($ADB shell 'echo "up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) boot=$(cat /proc/sys/kernel/random/boot_id)"' 2>&1 | tr -d '\r')
    echo "$TS  $L" >> "$OUT"
    i=$((i+1))
    sleep 10
done
echo "# exp6b timeline end $(date '+%F %T')" >> "$OUT"
