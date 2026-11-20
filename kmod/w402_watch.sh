#!/usr/bin/env bash
# 格 V(20 发) 判据线监视：insmod up=4425.70 ⇒ 线=6225.70；主判据是 boot_id(会撞上被测流程自己的复位)。
B0=8f46bfb1-d3f7-4d5b-83a7-7459d8fe01ac
echo "起点 boot=$B0 判据线 up=6225.70 insmod up=4425.70(设备钟 20:56:45)"
i=0
while [ $i -lt 32 ]; do
    R=$(MSYS_NO_PATHCONV=1 adb shell 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) suw=$(pidof com.suw.manager) bid=$(cat /proc/sys/kernel/random/boot_id)' 2>/dev/null | tr -d '\r')
    echo "[$(date +%H:%M:%S)] $R"
    case "$R" in *bid=$B0) ;; *) echo "★boot 变了或读不到 ⇒ 复位/掉线，停"; break;; esac
    UP=$(sed -n 's/.*up=\([0-9.]*\).*/\1/p' <<<"$R" | cut -d. -f1)
    MOD=$(sed -n 's/.*mod=\([0-9]*\).*/\1/p' <<<"$R")
    [ "$MOD" = 0 ] && { echo "★mod=0 ⇒ 模块没了，停"; break; }
    [ "${UP:-0}" -ge 6300 ] && { echo "★过线(up=$UP≥6300) ⇒ 判活，停"; break; }
    i=$((i+1)); sleep 60
done
