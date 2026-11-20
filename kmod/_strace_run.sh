#!/system/bin/sh
# 内部跑：起调试守护 → 后台循环 fire @sushd → strace 挂守护 25s → 落 sushd.strace
pkill -f ksuctl88_dbg 2>/dev/null; pkill -f "strace -f" 2>/dev/null; sleep 1
rm -f /data/local/tmp/sushd.strace /data/local/tmp/sushd.log /data/local/tmp/sushd.strace.info
setsid /data/local/tmp/ksuctl88_dbg sushd changeme </dev/null >>/data/local/tmp/sushd.log 2>&1 &
sleep 2
DP=$(pgrep -f ksuctl88_dbg | head -1)
echo "DP=$DP suwksu=$(grep -ac suwksu /proc/net/unix)" >> /data/local/tmp/sushd.strace.info
( i=0; while [ $i -lt 8 ]; do am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd "@sushd:/data/local/tmp/tr.sh" >/dev/null 2>&1; sleep 3; i=$((i+1)); done ) >/dev/null 2>&1 &
timeout 26 /data/local/tmp/strace -f -p "$DP" -e trace=execve,openat -o /data/local/tmp/sushd.strace </dev/null >/dev/null 2>&1
echo "DONE lines=$(wc -l < /data/local/tmp/sushd.strace 2>/dev/null)" >> /data/local/tmp/sushd.strace.info
