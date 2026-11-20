#!/system/bin/sh
# w172b_uid.sh —— 后测里 LADDER 14 印的是 `uid=10667`(前测印 uid=0)：这一发把这件事读清楚，**不加任何过滤**。
#   要判的是两种完全不同的东西：① 写回把 escape 弄坏了(严重)；② 只是我这一格读数的形状/顺序问题(不重要)。
L=/data/local/tmp/w172b_uid.out
CTL=/data/local/tmp/ksuctl88
{
    : >"$L"
    chmod 666 "$L" 2>/dev/null
    exec >>"$L" 2>&1
    echo "=== U up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) enf=$(getenforce)"
    U1=$(cat /data/local/tmp/w168_u1.uid 2>/dev/null | tr -dc '0-9')
    echo "  U1=$U1  (跑这个任务自己的 Uid=$(awk '/^Uid/{print $2,$3,$4,$5}' /proc/self/status))"
    echo "--- 内核名单里现在有什么(granted 回读) ---"
    "$CTL" granted "$U1" 2>&1 | tail -4
    echo "--- 一笔完整的 grant(不过滤：GRANT_ROOT 的返回、降 uid、每一格 LADDER、exec 出去的 id 打印) ---"
    "$CTL" grant "$U1" /system/bin/id 2>&1
    echo "  (rc=$?)"
    echo "--- 再来一笔不带命令的(看 LADDER 全表) ---"
    "$CTL" grant "$U1" 2>&1 | tail -24
    echo "===== DONE"
} 2>&1
chmod 666 "$L" 2>/dev/null
