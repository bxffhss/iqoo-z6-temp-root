#!/system/bin/sh
exec >/sdcard/w453_ns.txt 2>&1
echo "NS up=$(cut -d" " -f1 /proc/uptime) uid=$(id -u) enf=$(/system/bin/getenforce)"
echo "pbin行数=$(grep -ac pbin /proc/self/mountinfo) bins=$(/system/bin/ls -A /product/bin | wc -l) su=$(/system/bin/ls /product/bin/su 2>&1 | head -1)"
echo "改道那条=$(ls /system/bin/su 2>&1 | head -1)"
echo "===== DONE"
