#!/system/bin/sh
# w589_watch_arm.sh —— 第 47 发：**在恢复执法之前**另起一条 root 的 `dmesg -w` 流，落到一个 shell 可读的件里。
#   为什么必须"之前"起：翻 MAC 之后两条 root 通道(@sushd / 默认形状的改道 su)同时关门(#172 那条铁律)，
#   就再没人能替我抓内核行了；而 dmesg.live 那条老跟随器是"轮询＋截断"的形状，第 45 发实测内容比 HB 落后 1000 秒 ⇒ 不可信。
#   ★这条是**流式**(`dmesg -wT`，toybox 0.8.9 支持 -w)，写进程已持有 /dev/kmsg 的 fd；
#     如果它在恢复执法那一刻停笔，那它自己的**最后一条时刻**就是"何时开始读不到"的证人(两种结果都有信息)。
OUT=/data/local/tmp/w589_watch_arm.out
LIVE=/data/local/tmp/w589_live.log
: > "$LIVE"
{
    echo "=== ARM up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) ==="
    /system/bin/nohup /system/bin/dmesg -wT > "$LIVE" 2>&1 &
    FP=$!
    echo "follower_pid=$FP"
    sleep 2
    echo "两秒后字节=$(wc -c < $LIVE)"
    chmod 666 "$LIVE" 2>/dev/null
    echo "ps_跟随器=$(ps -A -o PID,NAME 2>/dev/null | grep -a -c "^[ ]*$FP")"
    echo "===== DONE"
} > "$OUT" 2>&1
chmod 666 "$OUT" 2>/dev/null
