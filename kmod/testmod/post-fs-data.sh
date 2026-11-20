#!/system/bin/sh
# 自制测试模块的脚本类判据：由 runner 以 root 直接执行(★绝不调 su —— 那条支路会命中 sucompat 改写到 ksud)
OUT=/data/local/tmp/ksu_mod_selftest.txt
{
  echo "uid=$(id -u) euid=$(id -u) gid=$(id -g)"
  echo "enforce=$(getenforce)"
  echo "comm=$0"
  echo "hosts_first_line=$(head -1 /system/etc/hosts)"
  echo "hosts_marker_seen=$(grep -c suw-module-marker /system/etc/hosts)"
  echo "can_write_data_adb=$(touch /data/adb/.suwtest 2>&1 && echo ok || echo fail)"
} > "$OUT" 2>&1
sync
