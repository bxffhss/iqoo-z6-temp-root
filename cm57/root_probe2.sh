#!/system/bin/sh
# root_probe2.sh <slide-hex> — 把"运行时内核修补"那格判生死: BPF 程序加载/挂 kprobe/读内核内存/helper 142
L=/data/local/tmp/root_probe2.log
rm -f $L
exec >> $L 2>&1
S=$1
echo "=== root_probe2 开始 uptime=$(cat /proc/uptime) slide=$S ==="
id
echo "--- A) kgate: kprobe + bpf map/prog + perf SET_BPF + bpf_probe_read 正对照 ---"
/data/local/tmp/kgate $S
echo "A_rc=$?"
echo "--- B) 动态事件里有没有残留(确认 kgate 自己摘干净了) ---"
cat /sys/kernel/tracing/kprobe_events
echo "--- C) 活的内核日志里抓 avc/bug/oops 关键字(root 下 dmesg 可读) ---"
dmesg 2>&1 | grep -icE 'avc:.*denied|bug:|oops|kernel BUG'
dmesg 2>&1 | grep -iE 'avc:.*denied' | tail -4
echo "=== root_probe2 结束 uptime=$(cat /proc/uptime) ==="
sync
