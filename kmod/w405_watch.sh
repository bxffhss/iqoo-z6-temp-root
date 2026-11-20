#!/usr/bin/env bash
# 第 22 发＝交付默认形状端到端回归的判活线：insmod up=774.02 ⇒ 线 up≥2574.02(设备钟约 23:48:32)。
#   主判据是 boot_id —— 它会撞上被测流程自己的复位(例 101：adb 不在线是计划内状态，不是失败)。
#   这一发不带任何实验开关：无 QUIET／无 NOFIRE／无 AP_KEY／args=交付五条。先验风险=152/19 发同 key(com.suw.manager)判死。
B0=4340dd5b-b46b-4d20-ac5e-726efbc4ac5a
LINE=2574
echo "起点 boot=$B0 insmod up=774.02 判活线 up>=$LINE (开枪 23:03, 装载 23:18:32)"
i=0
while [ $i -lt 32 ]; do
    R=$(MSYS_NO_PATHCONV=1 adb shell 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) suw=$(pidof com.suw.manager) bid=$(cat /proc/sys/kernel/random/boot_id)' 2>/dev/null | tr -d '\r')
    echo "[$(date +%H:%M:%S)] $R"
    case "$R" in *bid=$B0) ;; *) echo "★boot 变了或读不到 ⇒ 复位/掉线，停"; break;; esac
    UP=$(sed -n 's/.*up=\([0-9.]*\).*/\1/p' <<<"$R" | cut -d. -f1)
    MOD=$(sed -n 's/.*mod=\([0-9]*\).*/\1/p' <<<"$R")
    [ "$MOD" = 0 ] && { echo "★mod=0 ⇒ 模块没了，停"; break; }
    [ "${UP:-0}" -ge "$LINE" ] && { echo "★过线(up=$UP≥$LINE) ⇒ 判活，停"; break; }
    i=$((i+1)); sleep 60
done
