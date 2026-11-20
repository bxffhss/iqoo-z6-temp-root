#!/usr/bin/env bash
# 格 Y(154) 判据线监视：insmod up=2213.17 ⇒ 线=4013.17；主判据是 boot_id(这条腿会撞上被测流程自己的复位)。
B0=5dbb0082-8dfc-47b7-aec0-e2208ef6ce6a
echo "起点 boot=$B0  判据线 up=4013.17  insmod up=2213.17(设备钟 15:32:02)"
i=0
while [ $i -lt 32 ]; do
    R=$(MSYS_NO_PATHCONV=1 adb shell 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) suw=$(pidof com.suw.manager) bid=$(cat /proc/sys/kernel/random/boot_id)' 2>/dev/null | tr -d '\r')
    echo "[$(date +%H:%M:%S)] $R"
    case "$R" in *bid=$B0) ;; *) echo "★boot 变了或读不到 ⇒ 复位/掉线，停"; break;; esac
    UP=$(sed -n 's/.*up=\([0-9.]*\).*/\1/p' <<<"$R" | cut -d. -f1)
    MOD=$(sed -n 's/.*mod=\([0-9]*\).*/\1/p' <<<"$R")
    [ "$MOD" = 0 ] && { echo "★mod=0 停"; break; }
    [ "${UP:-0}" -ge 4100 ] && { echo "★过线(up=$UP≥4100) ⇒ 判活，停"; break; }
    i=$((i+1)); sleep 60
done
