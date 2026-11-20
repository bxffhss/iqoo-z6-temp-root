#!/bin/bash
# w1223 —— 「死前现场」采集器（第 18 枪起用），PC 侧约 3 s/拍（adb 往返主导），全只读 /proc
#
# ★为什么必须有这一支：
#   go.sh 的 RING_END_DUMP 下限是 30 秒（go.sh:141），而死线是 insmod+19.5 s
#   ⇒ 那个"死前整环 dump"从建成起就没有任何一发能生效；第 15 枪内核日志只覆盖到
#   insmod+6.4 s，死亡在 +19.3 s，中间 13 秒全盲。机制一直没证到，这是直接原因。
#   本采集器不经 dmesg、不需要 root、不经 stage 抽取，与第 16/17 枪证明可靠的
#   /proc/ksu_ser 拉取式同一族，第一次把死前 19 秒填满。
#
# 采什么：CPU 各态 jiffies（挂死会停滞）、loadavg、PSI、MemFree/Slab/SUnreclaim、
#         /proc/modules 的 mod 位、/proc/ksu_ser 见证行；每拍自带同源 up= 与 boot=。
# ★$ADB 不能加引号（加了会变成"整串当命令名"，每拍都 OFFLINE，第 16 枪踩过）。
set -u
cd "$(dirname "$0")/.." || exit 1
ADB="C:/adb/platform-tools/adb.exe -s <DEVICE_SERIAL>"
OUT=${OUT:-"kmod/w103_evidence/deathbed_$(date +%m%d-%H%M).txt"}
: > "$OUT"
echo "# deathbed start $(date '+%F %T')  (~3s/tick, max 2400)  out=$OUT" >> "$OUT"

# 防止设备挂死时 adb shell 永久阻塞（Git Bash coreutils 提供 timeout）
TO=""
if command -v timeout >/dev/null 2>&1; then TO="timeout 4"; fi

PROBE='S=$(cat /proc/ksu_ser 2>/dev/null | tr -d "\r\n"); U=$(cut -d" " -f1 /proc/uptime); B=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8); M=$(grep -c "^kernelsu " /proc/modules 2>/dev/null); J=$(head -1 /proc/stat | tr -s " " | cut -d" " -f2-6 | tr " " "+"); L=$(cut -d" " -f1-3 /proc/loadavg | tr " " "/"); F=$(grep -m1 MemFree /proc/meminfo | tr -dc "0-9"); SL=$(grep -m1 "^Slab:" /proc/meminfo | tr -dc "0-9"); SU=$(grep -m1 SUnreclaim /proc/meminfo | tr -dc "0-9"); P=$(head -1 /proc/pressure/cpu 2>/dev/null | tr " " "_"); echo "up=$U boot=$B mod=$M jif=$J load=$L memfree=$F slab=$SL sunr=$SU psi=${P:-NA} | ${S:-NOSER}"'

i=0; dead=0; seenmod=0; seen=0
while [ "$i" -lt 2400 ]; do
    TS=$(date '+%F %T')
    L=$($TO $ADB shell "$PROBE" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    if [ -z "$L" ]; then
        dead=$((dead+1)); L="OFFLINE"
    else
        dead=0
        case "$L" in *"mod=1"*) seenmod=1;; esac
        case "$L" in *SERD*) seen=$((seen+1));; esac
    fi
    echo "$TS  $L" >> "$OUT"
    # 只在"已经见过 mod=1 之后"才允许因掉线收工：开火早期要穿过一次 reboot
    [ "$dead" -ge 6 ] && [ "$seenmod" = 1 ] && {
        echo "$TS  # 连续 6 拍 OFFLINE ⇒ 收工（SERD 行数=$seen）" >> "$OUT"; break; }
    i=$((i+1))
    sleep 1
done
echo "# deathbed end $(date '+%F %T')  SERD 行数=$seen" >> "$OUT"
