#!/usr/bin/env bash
# 第 24 发＝**当前工具链**(go.sh 2b316637 / stage 78557b3f / sampler 8785d116 / ko rc67 40e0c25d / args 67199f48)
#   的交付默认形状回归：零实验开关。判活线现算＝insmod up + 1800 秒，不写死常数的第二种用法(抄 22 发)。
#   主判据是 boot_id —— 它会撞上被测流程自己的复位(例 101：adb 不在线是计划内状态，不是失败)。
B0=85ad6771-6f18-4807-b196-29846ac78400
INSMOD_UP=602.25
LINE=$(awk -v A="$INSMOD_UP" 'BEGIN{printf "%d", A+1800}')
echo "起点 boot=$B0 insmod up=$INSMOD_UP 判活线 up>=$LINE (装载 11:13:15，线约 11:43:15)"
i=0
while [ $i -lt 34 ]; do
    R=$(MSYS_NO_PATHCONV=1 adb shell 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) suw=$(pidof com.suw.manager) bid=$(cat /proc/sys/kernel/random/boot_id)' 2>/dev/null | tr -d '\r')
    echo "[$(date +%H:%M:%S)] $R"
    case "$R" in *bid=$B0) ;; *) echo "★boot 变了或读不到 ⇒ 复位/掉线，停"; break;; esac
    UP=$(sed -n 's/.*up=\([0-9.]*\).*/\1/p' <<<"$R" | cut -d. -f1)
    MOD=$(sed -n 's/.*mod=\([0-9]*\).*/\1/p' <<<"$R")
    [ "$MOD" = 0 ] && { echo "★mod=0 ⇒ 模块没了，停"; break; }
    [ "${UP:-0}" -ge "$LINE" ] && { echo "★过线(up=$UP≥$LINE) ⇒ 判活，停"; break; }
    i=$((i+1)); sleep 60
done
