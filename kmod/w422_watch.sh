#!/usr/bin/env bash
# w422_watch.sh —— 判活跟随器(第 25 发起用)。逻辑照抄 w410_watch.sh，但**两个常数改成入参**：
#   写死在文件里＝每一发都要手改一遍，而"忘了改"的形状是拿上一发的 boot/起点当判据(会判出一张假活表)。
#   用法：bash kmod/w422_watch.sh <本 boot 的 boot_id> <insmod 那行的 up>
#   判活线现算：up ≥ insmod_up + 1800(=30 分钟)。主判据是 boot_id(例 101：adb 不在线是被测流程自己的复位，不是失败)。
#   自测＝bash kmod/_tmp_selftest_rdst/run_watch.sh(三格，桩 adb，不碰设备)
set -u
# ★自测在 kmod/_tmp_selftest_rdst/run_watch.sh(切片式，桩 adb)——放在本文件里会让"数自己文案"的护栏假红(例 127②)。
[ $# -ge 2 ] || { echo "[x] 用法：bash kmod/w422_watch.sh <boot_id> <insmod_up>"; exit 2; }
B0=$1
INSMOD_UP=$2
case "$INSMOD_UP" in *[!0-9.]*|"") echo "[x] insmod_up 必须是数字(收到 [$INSMOD_UP])"; exit 2;; esac
LINE=$(awk -v A="$INSMOD_UP" 'BEGIN{printf "%d", A+1800}')
echo "起点 boot=$B0 insmod up=$INSMOD_UP 判活线 up>=$LINE (起表时刻 $(date +%H:%M:%S))"
i=0
while [ $i -lt 36 ]; do
    ROW=$(MSYS_NO_PATHCONV=1 adb shell 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) bid=$(cat /proc/sys/kernel/random/boot_id)' 2>/dev/null | tr -d '\r')
    echo "[$(date +%H:%M:%S)] $ROW"
    case "$ROW" in *bid=$B0) ;; *) echo "★boot 变了或读不到 ⇒ 复位/掉线，停"; break;; esac
    UP=$(sed -n 's/.*up=\([0-9.]*\).*/\1/p' <<<"$ROW" | cut -d. -f1)
    MOD=$(sed -n 's/.*mod=\([0-9]*\).*/\1/p' <<<"$ROW")
    [ "$MOD" = 0 ] && { echo "★mod=0 ⇒ 模块没了，停"; break; }
    [ "${UP:-0}" -ge "$LINE" ] && { echo "★过线(up=$UP≥$LINE) ⇒ 判活，停"; break; }
    i=$((i+1)); sleep 60
done
