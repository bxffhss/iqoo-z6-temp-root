#!/usr/bin/env bash
# w356_arm_after_boot.sh —— **修正第 122 发那个我自己造的盲区**：采样腿必须等"这一 boot 起来之后"再起。
#
# ★事故(§6.263③)：`w356_window_prep.sh` 在 **reboot 之前**就把采样器起了 ⇒ 它只录到开窗前 ~40 秒的空转，
#   然后被 reboot 一起杀掉；设备上那条曲线在 insmod(真正要看的那一刻)之前**根本不存在**。
#   宿主机侧那条腿反倒因为跨 reboot 而拿到了 insmod/复位时刻的名单——这就是"活落盘要独立于被测流程"的反面教材。
# 用法(与 go.sh **并行**跑，不要串行)：
#   1) bash kmod/w356_window_prep.sh            # 铺脚本+闸(不再起采样)
#   2) KO=kmod/kernelsu_rc67.ko I_KNOW=1 bash kmod/go.sh   &    # 开窗(它会 reboot)
#   3) bash kmod/w356_arm_after_boot.sh         # 本脚本：等 boot_completed ⇒ 起曲线
set -u
export MSYS_NO_PATHCONV=1
N=${1:-1500}          # 1500 × ~1.05s ≈ 26 分钟(boot 之后到 insmod 实测 7~8 分钟，再加窗口寿命，够用)
S(){ timeout 30 adb shell "$1" 2>&1 | tr -d '\r'; }

echo "=== 1) 等这一 boot 起来(boot_completed=1 再多等 25 秒) ==="
for i in $(seq 1 120); do
    BC=$(S "getprop sys.boot_completed" | tr -dc '0-9')
    [ "$BC" = 1 ] && { echo "  boot_completed=1 (第 $i 次轮询, $(date +%H:%M:%S))"; break; }
    [ $((i % 10)) -eq 0 ] && echo "    还在等开机: 第 $i 次 ($(date +%H:%M:%S))"
    sleep 10
done
[ "$BC" = 1 ] || { echo "[x] 等满 20 分钟没起来 ⇒ 停(这一发的 reboot 没成功或机器掉了)"; exit 3; }
sleep 25

echo; echo "=== 2) 起曲线之前先把**同名残留**清掉(例 77 的第二形态：跨 boot 相接的曲线比日志更难发现) ==="
S "rm -f /data/local/tmp/w356_storm.out"
GONE=$(S "ls /data/local/tmp/w356_storm.out 2>&1" | head -1)
echo "  复证=[$GONE]"; case "$GONE" in *"No such file"*) ;; *) echo "[x] 旧曲线没删掉 ⇒ 停(两 boot 的曲线接在同一个文件里，速率判据会算出假东西)"; exit 3;; esac

echo; echo "=== 3) 起采样(设备侧固定 1 fork/秒)并立刻回读两行 ==="
S "setsid nohup /data/local/tmp/w356_storm_dev.sh $N >/dev/null 2>&1 </dev/null &"
sleep 6
S "head -2 /data/local/tmp/w356_storm.out; echo 当前 up=\$(cut -d' ' -f1 /proc/uptime)" | sed 's/^/  /'
echo
echo "★接下来量完读这两条(复位也带得走，文件在 /data)："
echo '    MSYS_NO_PATHCONV=1 adb pull //data/local/tmp/w356_storm.out kmod/w103_evidence/<这一发的名>.out'
echo '    PYTHONUTF8=1 python kmod/w356_rate.py kmod/w103_evidence/<这一发的名>.out'
echo "★提醒：起采样的时刻记进存证(它比 insmod 早 7~8 分钟)，R0 用的是 **insmod 后 5~15 秒**那一段，不是采样开头。"
