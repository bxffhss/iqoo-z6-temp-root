#!/system/bin/sh
# w813_enforce_only.sh —— 第 56 发的**只做一件事**的腿：恢复执法（root 腿全跑完之后的最后一步）。
#   ★无参数：打字尾参会被输入法吃掉(第 54 发一手)；★产物权限写在最前面(同一条一手)。
L=/data/local/tmp/w813.out
: > "$L" 2>/dev/null
chmod 666 "$L" 2>/dev/null
{
    echo "=== 只恢复执法 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf_before=$(cat /sys/fs/selinux/enforce 2>/dev/null) mod=$(grep -c kernelsu /proc/modules) ==="
    echo 1 > /sys/fs/selinux/enforce 2>/dev/null
    echo "  写 rc=$? 回读=$(cat /sys/fs/selinux/enforce 2>/dev/null) getenforce=$(/system/bin/getenforce 2>/dev/null) mod=$(grep -c kernelsu /proc/modules)"
    echo "  落点现在=[$(/system/bin/ls -A /product/bin 2>/dev/null | tr '\n' ' ')] mountinfo_pbin 行=$(grep -ac pbin /proc/self/mountinfo 2>/dev/null) ★我这侧的 ns 可能仍留着挂载(第 56 发实测 umount 不跨 ns)——reboot 会一起收掉"
    sync
    echo "=== 完 up=$(cut -d' ' -f1 /proc/uptime) ==="
} >> "$L" 2>&1
