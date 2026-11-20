#!/system/bin/sh
# w501_probe.sh —— 只自证"我是谁、内核里那个 ko 还在不在、这条读数是哪一刻拍的"。
#   ★判据落在自己的 .out(root 写 ⇒ 立刻 chmod 666，否则 shell 读不回会被误判成"没跑")。
O=/data/local/tmp/w501_probe.out
: > "$O"
chmod 666 "$O" 2>/dev/null
echo "who=$(id)" >> "$O"
echo "up=$(cat /proc/uptime)" >> "$O"
echo "mod=$(grep -ac '^kernelsu ' /proc/modules)" >> "$O"
echo "enf=$(getenforce)" >> "$O"
echo "z64=$(pidof zygote64)" >> "$O"
echo "ss=$(pidof system_server)" >> "$O"
echo "PPID_chain=$(cat /proc/self/status | grep -a '^PPid' )" >> "$O"
sync
echo PROBE_DONE >> "$O"
