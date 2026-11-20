#!/system/bin/sh
pkill -f "ksuctl88 sushd" 2>/dev/null; pkill -f "ksuctl88_dbg sushd" 2>/dev/null; pkill -f "sushd changeme" 2>/dev/null; sleep 1
rm -f /data/local/tmp/sushd.log
setsid /data/local/tmp/ksuctl88 sushd changeme </dev/null >>/data/local/tmp/sushd.log 2>&1 &
sleep 2
echo "daemon_pid=$(pgrep -f 'ksuctl88 sushd' | head -1) suwksu=$(grep -ac suwksu /proc/net/unix)" > /data/local/tmp/sushd.start
