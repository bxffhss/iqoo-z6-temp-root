#!/bin/bash
# w1219 —— 第 17 枪（Exp-8c 一次性进入）的**拉取式**见证采集器（1 s/拍）
#   为什么不用 dmesg：第 15 枪查明 stage 那份内核日志是被过滤的子集（连无条件必打的
#   KSUBEAT M2/M3/M5 都不在里面）⇒ "打印为 0" 推不出 "路径没跑"。
#   这里直接 cat /proc/ksu_ser（ko 里 read 时现算），全程不碰内核环形缓冲。
#   同时记 up=/mod=/boot= 以便死亡时刻只用同源 up=（不拿 epoch 夹）。
set -u
cd "$(dirname "$0")/.." || exit 1
ADB="C:/adb/platform-tools/adb.exe -s <DEVICE_SERIAL>"
OUT=kmod/w103_evidence/exp8c_once_poll.txt
: > "$OUT"
echo "# exp8c poll start $(date '+%F %T')  (1s/tick, max 600)" >> "$OUT"
i=0; dead=0; seen=0; seenmod=0
while [ "$i" -lt 1500 ]; do
    TS=$(date '+%F %T')
    # ★一条 adb shell 里同时取 SERD 与 up/mod/boot，避免两次往返把时序拆散
    L=$($ADB shell 'S=$(cat /proc/ksu_ser 2>/dev/null | tr -d "\r\n"); U=$(cut -d" " -f1 /proc/uptime); M=$(grep -c "^kernelsu " /proc/modules 2>/dev/null); B=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8); echo "up=$U mod=$M boot=$B | ${S:-NOSER}"' 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    if [ -z "$L" ]; then
        dead=$((dead+1)); L="OFFLINE"
    else
        dead=0
        case "$L" in *SERD*) seen=$((seen+1));; esac
        case "$L" in *"mod=1"*) seenmod=1;; esac
    fi
    echo "$TS  $L" >> "$OUT"
    # ★只在"已经见过 mod=1 之后"才允许因掉线收工：开火早期要穿过一次 reboot，
    #   那时连续 OFFLINE 是正常的，不能当死亡（第 15 枪吃过这个误判的边）
    [ "$dead" -ge 6 ] && [ "$seenmod" = 1 ] && { echo "$TS  # 连续 6 拍 OFFLINE ⇒ 收工（SERD 行数=$seen）" >> "$OUT"; break; }
    i=$((i+1))
    sleep 1
done
echo "# exp8c poll end $(date '+%F %T')  SERD 行数=$seen" >> "$OUT"
