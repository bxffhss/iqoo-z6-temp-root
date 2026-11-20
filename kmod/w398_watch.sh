#!/usr/bin/env bash
# 格 X(第 16 发＝153) 的判据线监视：每 60 秒读一次 up/mod/boot_id。
#   停的条件：boot_id 变了(＝复位)、或 mod=0(＝模块没了)、或 up>=2700(过判据线 848.12+1800=2648.12)。
#   ★这条腿自己会碰上"被测流程自己的重启"，所以 boot_id 是主判据，不是 up(例 101)。
B0=$(MSYS_NO_PATHCONV=1 adb shell 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n')
echo "起点 boot_id=$B0  判据线 up=2648.12  insmod up=848.12(设备钟 13:11:25)"
i=0
while [ $i -lt 30 ]; do
    R=$(MSYS_NO_PATHCONV=1 adb shell 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) bid=$(cat /proc/sys/kernel/random/boot_id)' 2>/dev/null | tr -d '\r')
    echo "[$(date +%H:%M:%S)] $R"
    case "$R" in *bid=$B0) ;; *) echo "★boot_id 变了或读不到 ⇒ 判读：复位/掉线，停"; break;; esac
    UP=$(sed -n 's/.*up=\([0-9.]*\).*/\1/p' <<<"$R" | cut -d. -f1)
    MOD=$(sed -n 's/.*mod=\([0-9]*\).*/\1/p' <<<"$R")
    [ "$MOD" = 0 ] && { echo "★mod=0 ⇒ 模块没了，停"; break; }
    [ "${UP:-0}" -ge 2700 ] && { echo "★过判据线(up=$UP≥2700) ⇒ 判活，停"; break; }
    i=$((i+1)); sleep 60
done
