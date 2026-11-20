#!/system/bin/sh
OUT=/data/local/tmp/w233_probe.out
exec >"$OUT" 2>&1
echo "ts=$(date +%Y-%m-%dT%H:%M:%S) uid=$(id -u)"
echo "=== /data/adb 全量 ==="
ls -la /data/adb/ 2>&1
echo "=== modules ==="
ls -la /data/adb/modules/ 2>&1
echo "--- modules_update ---"
ls -laR /data/adb/modules_update/ 2>&1 | head -60
echo "=== service.d ==="
ls -la /data/adb/service.d/ 2>&1
echo "=== ZN daemon fd/maps（模块 so 是否还被持有） ==="
for p in $(pidof zn-daemon 2>/dev/null); do
  echo "pid=$p"
  ls -l /proc/$p/fd 2>/dev/null | grep -aE 'zygisk|lsposed|modules|\.so' | head -20
  echo "--- maps ---"
  grep -aE 'zygisk|lsposed|\.so' /proc/$p/maps 2>/dev/null | head -15
done
echo "=== zygisksu 状态目录 ==="
ls -la /data/adb/zygisksu/ 2>&1
echo "=== ksu 相关进程 ==="
ps -A -o PID,PPID,UID,NAME,CMD 2>/dev/null | grep -aiE 'ksud|ksu|shd|stage' | grep -av grep | head -20
echo "===== DONE"
