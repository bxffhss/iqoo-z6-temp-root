#!/system/bin/sh
# w124_log.sh —— **独立于 stage 的常驻现场抓取**（md §6.120）
#   第一百一十九发的教训：stage 自己的 dumper 会在收尾时 `kill $LV`，于是"死前最后几行"根本没落盘
#   ——我据此把"572.65 之后没有 KernelSU 回执"读成"死在 handler 之前"，其实那是**眼睛先闭上了**。
#   ⇒ 由 root 守护(sushd，比 stage 活得久)起一个脱离会话的循环：每 2 秒把 dmesg 追加落盘 + sync。
#   机器一复位，文件里一定有最后几行（本机 console=null、pstore 空，这条是唯一的事后通路）。
L=/data/local/tmp/dmesg2.log
P=/data/local/tmp/dmesg2.pid
{
    echo "=== 起点 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    if [ -f "$P" ] && kill -0 "$(cat $P 2>/dev/null)" 2>/dev/null; then
        echo "已有常驻 dumper pid=$(cat $P) ⇒ 不重复起"
        exit 0
    fi
    rm -f "$L"
    # 每 2 秒**整份覆盖** + sync：文件恒等于当前环形缓冲 ⇒ 不会像追加那样几分钟就涨到几十 MB，
    # 而复位后能拿到的最多只丢最后 2 秒(本机 console=null、pstore 空，这是唯一的事后通路)。
    setsid nohup sh -c '
        i=0
        while [ $i -lt 20000 ]; do
            dmesg > /data/local/tmp/dmesg2.log.tmp 2>&1
            mv -f /data/local/tmp/dmesg2.log.tmp /data/local/tmp/dmesg2.log
            sync
            i=$((i + 1))
            sleep 2
        done
    ' >/dev/null 2>&1 &
    echo $! > "$P"
    chmod 666 "$P" 2>/dev/null
    sleep 3
    echo "常驻 dumper pid=$(cat $P) 第一份大小=$(wc -c < $L 2>/dev/null)"
} > /data/local/tmp/w124_log.out 2>&1
chmod 666 /data/local/tmp/w124_log.out /data/local/tmp/dmesg2.log 2>/dev/null
