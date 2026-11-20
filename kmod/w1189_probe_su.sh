#!/system/bin/sh
OUT=/data/local/tmp/w1189_probe_su.out
: > "$OUT"
echo "=== root $(id) ===" >> "$OUT"
echo "--- /data/adb 树 ---" >> "$OUT"
ls -ld /data/adb /data/adb/ksu /data/adb/ksu/bin 2>&1 >> "$OUT"
ls -l /data/adb/ksu/bin/ 2>&1 >> "$OUT"
echo "--- su/ksud 文件属性 ---" >> "$OUT"
for p in /data/adb/ksu/bin/su /data/adb/ksu/bin/ksud /data/adb/ksud /data/adb/ksu/lib/libksud.so; do
  printf "%-36s " "$p" >> "$OUT"
  ls -l "$p" 2>&1 | tr -s ' ' >> "$OUT"
done
echo "--- md5 / file 类型 ---" >> "$OUT"
md5sum /data/adb/ksu/bin/su /data/adb/ksu/bin/ksud 2>&1 >> "$OUT"
head -c 20 /data/adb/ksu/bin/su 2>/dev/null | od -An -tx1 >> "$OUT"
echo "--- 我编的 ksu_su 对比 ---" >> "$OUT"
md5sum /data/local/tmp/ksu_su 2>&1 >> "$OUT"
echo "--- /data/adb 下其它内容 ---" >> "$OUT"
ls -la /data/adb 2>&1 >> "$OUT"
echo "--- 官方 Manager 版本 ---" >> "$OUT"
dumpsys package me.weishu.kernelsu 2>/dev/null | grep -E "versionName|versionCode" | head -4 >> "$OUT"
echo "--- ksu 相关 mount ---" >> "$OUT"
grep -Ei "ksu|kernelsu|overlay" /proc/mounts 2>&1 >> "$OUT"
echo "===== DONE =====" >> "$OUT"
