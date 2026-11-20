#!/system/bin/sh
# w500_soft.sh —— 设备侧"软重启"载荷，照 iqooz5 的 soft_reboot(软重启).sh 形状：
#   只 kill zygote/system_server(=> init 重拉、framework 全新)，**不动内核**、不动已加载的 ko。
# ★三条形状纪律(都是这里以前的教训换来的)：
#   ①判据全部写进自己的 .out —— **生产者就是本脚本**(否则 rleg 那种"等回执"会造出假红，#172)；
#   ②.out 先 chmod 666 —— root 留下的 0600 会让 shell 读不回，"读不到"会被当成"没跑"(例：Permission denied 反证)；
#   ③kill 放在**所有落盘＋sync 之后**——我们自己就是 Termux(zygote 的孙子)的子进程，框架一重启先把我们杀掉，
#     任何写在 kill 之后的行都可能不落地，所以最后一行"echo killed"只当装饰，**绝不作为判据**。
O=/data/local/tmp/w500_soft.out
: > "$O"
chmod 666 "$O" 2>"$O.chmod"
echo "up=$(cat /proc/uptime)" >> "$O"
echo "mod=$(grep -ac '^kernelsu ' /proc/modules)" >> "$O"
echo "enf=$(getenforce)" >> "$O"
echo "who=$(id)" >> "$O"
echo "z64=$(pidof zygote64)" >> "$O"
echo "z32=$(pidof zygote)" >> "$O"
echo "ss=$(pidof system_server)" >> "$O"
echo "tmx=$(pidof com.termux)" >> "$O"
echo "boot_completed=$(getprop sys.boot_completed)" >> "$O"
sync
kill -9 $(pidof system_server) $(pidof zygote64) $(pidof zygote) 2>/dev/null
echo "KILLED_LINE_MAY_NOT_LAND rc=$?" >> "$O"
