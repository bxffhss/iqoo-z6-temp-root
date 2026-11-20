#!/system/bin/sh
O=/data/local/tmp/w207_read.out
exec >"$O" 2>&1
echo "=== W207 读 su 结果 up=$(cut -d" " -f1 /proc/uptime) 我自己=$(id -u) ==="
echo "--- /data/local/tmp/w207_su.txt 内容(Termux 里 su 后 id -u 写的) ---"
cat /data/local/tmp/w207_su.txt 2>&1
ls -l /data/local/tmp/w207_su.txt 2>&1
echo "=== DONE ==="
chmod 666 "$O"
