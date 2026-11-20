#!/system/bin/sh
O=/data/local/tmp/w208_read.out
exec >"$O" 2>&1
echo "=== W208 读探针结果 up=$(cut -d" " -f1 /proc/uptime) uid=$(id -u) ==="
ls -lZ /data/data/com.termux/files/home/w208.txt 2>&1
cat /data/data/com.termux/files/home/w208.txt 2>&1
echo "=== DONE ==="
chmod 666 "$O"
