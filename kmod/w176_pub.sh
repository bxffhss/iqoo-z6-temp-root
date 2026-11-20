#!/system/bin/sh
L=/data/local/tmp/w176_pub.out
{
  echo "=== PUB up=$(cut -d" " -f1 /proc/uptime) uid=$(id -u)"
  ls -l /data/local/tmp/uu_root.txt 2>&1
  cat /data/local/tmp/uu_root.txt 2>&1
  cp /data/local/tmp/uu_root.txt /data/local/tmp/uu_pub.txt 2>&1
  chmod 666 /data/local/tmp/uu_pub.txt 2>&1
  echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L" 2>/dev/null
