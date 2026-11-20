#!/system/bin/sh
# w128_uninstall_su.sh —— 收尾：把装进别人私有目录的静态 su 删掉（临时 root 不留持久化痕迹）
#   必须走 root 侧(@sushd:)：uid 2000 连 /data/data/com.termux 都进不去(实测 Permission denied)。
L=/data/local/tmp/w128_uninstall.out
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    for d in /data/data/com.termux/files/usr/bin /data/data/com.termux/files/usr/xbin; do
        echo "--- $d/su ---"
        ls -l "$d/su" 2>&1
        rm -f "$d/su" 2>&1
        ls -l "$d/su" 2>&1
    done
    echo "--- 顺带清 PC 侧推的临时件 ---"
    rm -f /data/local/tmp/sustatic /data/local/tmp/uu.txt /data/local/tmp/w130.out
    echo "done"
} >"$L" 2>&1
chmod 666 "$L"
