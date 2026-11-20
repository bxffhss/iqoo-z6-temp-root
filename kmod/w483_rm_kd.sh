#!/system/bin/sh
# w483_rm_kd.sh —— 台账 #161：改道落点 /data/local/tmp/kd 贴的是 apk_data_file，shell 连 mv/截断都被拒(§6.360③)，
#   只有 root 删得掉；本件在 Termux 的 root 壳里跑，输出自己写进 .out(★不靠屏幕：#116 已证 root 壳写不回 app 终端)。
#   ★删之前先确认这不是"窗口还没用完"：kd 是 su 改道的目标，删了 su 就 ENOENT，所以只能在判据腿全跑完后跑。
OUT=/data/local/tmp/w483_rm_kd.out
{
    echo "=== w483_rm_kd 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce 2>&1) ==="
    echo "删前："; ls -l /data/local/tmp/kd 2>&1
    rm -f /data/local/tmp/kd; echo "rm_rc=$?"
    ls -l /data/local/tmp/kd 2>&1 | sed 's/^/立即复证：/'
    sleep 5
    ls -l /data/local/tmp/kd 2>&1 | sed 's/^/等一拍复证：/'
    echo "=== DONE up=$(cut -d' ' -f1 /proc/uptime) ==="
} > $OUT 2>&1
sync
