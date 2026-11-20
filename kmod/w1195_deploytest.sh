#!/system/bin/sh
OUT=/data/local/tmp/w1195_deploytest.out
: > "$OUT"
echo "=== root=$(id -u) ===" >>"$OUT"
/system/bin/sh /data/local/tmp/su_deploy.sh
echo "su_deploy rc=$?" >>"$OUT"
echo "--- deploy 日志 ---" >>"$OUT"
cat /data/local/tmp/ksu_su_deploy.log >>"$OUT" 2>&1
echo "--- su 实测(10667 已授权) ---" >>"$OUT"
/data/local/tmp/asuid 10667 /system/bin/su -c id >>"$OUT" 2>&1
echo "rc=$?" >>"$OUT"
echo "--- 负对照(10349 现已被授权，改用 2000 shell) ---" >>"$OUT"
/data/local/tmp/asuid 2000 /system/bin/su -c id >>"$OUT" 2>&1
echo "rc=$?" >>"$OUT"
echo "===== DONE =====" >>"$OUT"
