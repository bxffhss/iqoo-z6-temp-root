#!/system/bin/sh
# w879: which SELinux domains exist here, and what our uid=0/shell root can actually read
echo "W879 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
echo "ID=$(id)"
echo "CTX=$(cat /proc/self/attr/current 2>&1)"
echo "-- domains present (uniq counts)"
ps -AZ 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -24
echo "-- sepolicy files readable?"
ls -l /system/etc/selinux 2>&1 | head -5
echo "-- visibility ladder for uid=0 in shell domain"
for P in /data/local/tmp /system/framework /data/system/packages.list /data/data /data/adb /sdcard/Android /data/misc /dev/kmsg /proc/1/limits; do
  if ls "$P" >/dev/null 2>&1; then echo "  OK   $P"; else echo "  DENY $P"; fi
done
echo "W879 END up=$(cut -d' ' -f1 /proc/uptime)"
