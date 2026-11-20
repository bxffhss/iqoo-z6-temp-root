#!/system/bin/sh
# w218_read.sh —— root 侧读腿：把 Termux 里那一枪的探针输出原样打印(本文件每次被覆盖，
#   所以**每个阶段跑完立刻 adb pull 一份到本地存证**，别等下一阶段盖掉——例39 那条)。
O=/data/local/tmp/w218_read.out
exec >"$O" 2>&1
echo "=== W218 读 su 探针 up=$(cut -d' ' -f1 /proc/uptime) 本腿域=$(cat /proc/self/attr/current 2>&1) 机器 enf=$(cat /sys/fs/selinux/enforce 2>&1) ==="
ls -l /data/data/com.termux/files/home/w218_su.txt 2>&1
echo "--- 第一份(app 私有目录，root 腿读) ---"
cat /data/data/com.termux/files/home/w218_su.txt 2>&1
echo "--- 第二份(scoped 外部目录；这份 **adb shell/adb pull 直接就读得到**，不必占 root 腿) ---"
cat /sdcard/Android/data/com.termux/files/w218_su.txt 2>&1
echo "--- 同一份从 /data/media 侧再对一次(两个来源) ---"
cat /data/media/0/Android/data/com.termux/files/w218_su.txt 2>&1 | head -3
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
