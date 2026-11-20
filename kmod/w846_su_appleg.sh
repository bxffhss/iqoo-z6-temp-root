#!/system/bin/sh
# w846: shipped-su (v3) argument-contract leg, driven from an app-range uid
echo "W846 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
echo "SELF=$(id)"
echo "KSUFD=$(ls -l /proc/self/fd 2>/dev/null | grep -ac ksu_driver)"
echo "FDCNT=$(ls /proc/self/fd 2>/dev/null | wc -w)"
SU=/product/bin/su

echo "CASE1 su -c id"
timeout 10 $SU -c id 2>&1
echo "RC1=$?"

echo "CASE2 su -v"
timeout 10 $SU -v 2>&1
echo "RC2=$?"

echo "CASE3 su 0 id"
timeout 10 $SU 0 id 2>&1
echo "RC3=$?"

echo "CASE4 su -M -c id"
timeout 10 $SU -M -c id 2>&1
echo "RC4=$?"

echo "CASE5 pipe echo id | su"
echo id | timeout 10 $SU 2>&1
echo "RC5=$?"

echo "CASE6 redirect-path su -c id"
timeout 10 /system/bin/su -c id 2>&1
echo "RC6=$?"

echo "W846 END up=$(cut -d' ' -f1 /proc/uptime)"
