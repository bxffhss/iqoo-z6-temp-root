#!/system/bin/sh
# np_test.sh —— 用 uid=10475(NP管理器) 的身份起一个 root 会话，看它到底能不能读受保护目录。
OUT=/data/local/tmp/np_test.out
{
  echo "=== asuid 10475 /product/bin/su ==="
  /data/local/tmp/asuid 10475 /product/bin/su -c 'id; echo "-- /data/adb --"; ls /data/adb 2>&1 | head -6; echo "-- /data/data --"; ls /data/data 2>&1 | head -4; echo "-- /data/system --"; ls /data/system 2>&1 | head -4; echo "-- /data/misc --"; ls /data/misc 2>&1 | head -4'
  echo "=== 对照：su 绝对路径逐个探 ==="
  for p in /product/bin/su /system/bin/su /system/xbin/su /sbin/su; do
    [ -e "$p" ] && echo "$p 存在" || echo "$p 不存在"
  done
  echo "DONE"
} > "$OUT" 2>&1
