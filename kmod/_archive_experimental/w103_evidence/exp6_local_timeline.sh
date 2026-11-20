#!/usr/bin/env bash
# exp6 (0x2 + ksu_exp6_mode=1 = 只留 sucompat handler 一支；ksud 与 sulog 两支护)
# 本地时间轴采样：纯只读，每 5s 一行。
# 跟踪 up/mod/enf/ksud/boot_id + punch.log 字节。与 go.sh 并发跑。
set -u
cd "$(dirname "$0")/../.." || exit 1
A="/c/adb/platform-tools/adb.exe -s <DEVICE_SERIAL>"
T="kmod/w103_evidence/exp6_local_timeline.txt"
: > "$T"
echo "# exp6 timeline start $(date '+%F %T')" >> "$T"
for i in $(seq 1 240); do
    TS=$(date '+%F %T')
    R=$($A shell 'echo -n "up="; cut -d" " -f1 /proc/uptime; echo -n " mod="; grep -c kernelsu /proc/modules; echo -n " enf="; getenforce; echo -n " ksud="; ls -l /dev/ksud 2>/dev/null | tr -s " "; echo -n " boot="; cat /proc/sys/kernel/random/boot_id; echo -n " punchB="; wc -c < /data/local/tmp/punch.log 2>/dev/null' 2>&1 | tr -d '\r')
    echo "$TS  $R" >> "$T"
    sleep 5
done
echo "# exp6 timeline end $(date '+%F %T')" >> "$T"
