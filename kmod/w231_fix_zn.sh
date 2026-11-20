#!/system/bin/sh
# w231_fix_zn.sh — 修 ZN daemon 启动：清 .injecting 残留锁 + 用 w210 验证过的形态启动
OUT=/data/local/tmp/w231_fix_zn.out
exec >"$OUT" 2>&1
M=/data/adb/modules/zygisksu
ZD=$M/bin/zygiskd
ZIP='/sdcard/Download/必备模块/Zygisk-Next-1.5.2-864-a4a72ce-relea.zip'
S=/system/bin/setsid
echo "ts=$(date +%H:%M:%S) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null)"
echo "mod=$(grep -c kernelsu /proc/modules) enf=$(cat /sys/fs/selinux/enforce)"

echo "########## [1] 清残留锁 + 从 ZIP 恢复 module.prop ##########"
rm -f /data/adb/zygisksu/.injecting /data/adb/zygisksu/.abort_msg
echo "RM_RC=$?  ls=[$(ls -a /data/adb/zygisksu 2>&1 | tr '\n' ' ')]"
/system/bin/unzip -o "$ZIP" 'module.prop' -d "$M" >/dev/null 2>&1
echo "module.prop hash=$(sha256sum "$M/module.prop" | awk '{print $1}')"

echo "########## [2] 先前台短跑，看 daemon 到底报什么 ##########"
timeout 6 "$ZD" daemon 2>&1; echo "FG_RC=$?"
echo "--- after FG: procs=[$(pidof zn-daemon)] abort=[$(cat /data/adb/zygisksu/.abort_msg 2>&1)] ---"

echo "########## [3] 清锁后再起（w210 成功形态：nohup + setsid，脱离） ##########"
rm -f /data/adb/zygisksu/.injecting /data/adb/zygisksu/.abort_msg
# w210 用的是 busybox setsid；现用系统 setsid + nohup 双 fork，全部 fd 断开
( nohup "$S" "$ZD" daemon >/data/local/tmp/w231_zn.log 2>&1 </dev/null & )
echo "SPAWN_RC=$?"
sleep 6
echo "--- procs ---"; ps -A -o PID,PPID,UID,NAME | grep -aiE 'zn-daemon|zygiskd' | head -10
echo "--- zn log ---"; cat /data/local/tmp/w231_zn.log 2>&1
echo "--- status ---"
timeout 8 "$ZD" status 2>&1; echo "STATUS_RC=$?"
echo "--- module.prop description ---"; grep -a '^description=' "$M/module.prop" 2>&1
echo "--- 状态目录 ---"; ls -la /data/adb/zygisksu/ 2>&1
echo "===== DONE"
