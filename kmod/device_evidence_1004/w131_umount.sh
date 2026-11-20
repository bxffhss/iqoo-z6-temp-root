#!/system/bin/sh
# w131_umount.sh —— 收尾：把 /system/bin 上的挂载卸掉，并**当场证明回到原状**。#   给 root 侧跑(@sushd:)。卸完必须看到 /system/bin/su 又"不存在"了 —— 这既是清理，
#   也是最后一格负对照：文件不在了，同一个 uid 的 su 探针就该退回失败。
L=${OUT:-/data/local/tmp/w131_umount.out}
CTL=/data/local/tmp/ksuctl86
U=$(cat /data/local/tmp/w131_tuid.txt 2>/dev/null); [ -n "$U" ] || U=10667
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    echo "--- 卸之前 /system/bin 上挂着什么(可能叠了两层：overlay 失败后又有 bind) ---"
    grep -a ' /system/bin ' /proc/self/mountinfo | cut -c1-140
    i=1
    while [ $i -le 4 ]; do
        grep -aq ' /system/bin ' /proc/self/mountinfo || break
        umount /system/bin >/data/local/tmp/w131_um.err 2>&1
        echo "  umount#$i rc=$?  $(cat /data/local/tmp/w131_um.err)"
        i=$((i+1))
    done
    echo "--- 卸之后 ---"
    echo "MOUNT_LEFT=$(grep -ac ' /system/bin ' /proc/self/mountinfo)"
    echo "SU_GONE=$(/system/bin/ls -l /system/bin/su 2>&1)"
    echo "SH_ALIVE=$(/system/bin/sh -c 'echo yes' 2>&1)"
    echo "BIN_COUNT=$(ls /system/bin 2>/dev/null | wc -l)"
    echo "--- 负对照(最后一格)：文件没了，同一个 uid 再敲一次 su，必须失败 ---"
    $CTL su "$U" "id" 2>&1
    echo "RC=$?"
    echo "--- 删目录 ---"
    rm -rf /data/local/tmp/subin /data/local/tmp/newbin && echo "RM_OK"
    echo "LEFT=$(ls -d /data/local/tmp/subin /data/local/tmp/newbin 2>&1)"
    echo "=== DONE up=$(cut -d' ' -f1 /proc/uptime) ==="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
