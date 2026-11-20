#!/system/bin/sh
# w209_recover.sh — 修 verify1 自伤 + 用 setsid 完全脱离地起 zygiskd daemon + 多次采样
# ★仍不碰 zygote / 不跑 ksud post-fs-data
OUT=/data/local/tmp/w209_recover.out
exec >"$OUT" 2>&1
M=/data/adb/modules
ZN=$M/zygisksu
ZIP='/sdcard/Download/必备模块/Zygisk-Next-1.5.2-864-a4a72ce-relea.zip'

echo "########## [1] module.prop diff (current vs orig) ##########"
echo "--- current module.prop ---"; cat "$ZN/module.prop"; echo
echo "--- module.prop.orig ---"; cat "$ZN/module.prop.orig"; echo
echo "--- expected sha256 ---"; cat "$ZN/module.prop.sha256"; echo
echo "--- current hash ---"; sha256sum "$ZN/module.prop"
echo "--- orig hash ---"; sha256sum "$ZN/module.prop.orig"

echo "########## [2] restore module.prop from ZIP (authoritative) ##########"
cd "$ZN" || exit 1
unzip -o "$ZIP" 'module.prop' -d "$ZN" >/dev/null 2>&1
cp -f "$ZN/module.prop" "$ZN/module.prop.orig"
echo "--- restored hash ---"; sha256sum "$ZN/module.prop"
echo "--- verify against .sha256 ---"
sha256sum -c "$ZN/module.prop.sha256" 2>&1 || true

echo "########## [3] clear abort markers ##########"
rm -f /data/adb/zygisksu/.abort_msg /data/adb/zygisksu/.injecting
ls -la /data/adb/zygisksu/

echo "########## [4] daemon launch (fully detached via busybox setsid) ##########"
BB=/data/adb/ksu/bin/busybox
echo "BB=$BB"; ls -la "$BB"
# 双 fork + setsid 脱离会话；stdin/stdout/stderr 全重定向
nohup "$BB" setsid "$ZN/bin/zygiskd" daemon >/data/local/tmp/w209_znd.log 2>&1 </dev/null &
echo "SPAWN_PID=$!"

echo "########## [5] sample at t+3 ##########"
sleep 3
echo "--- procs ---"; ps -A -o PID,PPID,UID,NAME | grep -aiE 'zygisk|zn-daemon|machikado'
echo "--- daemon log ---"; cat /data/local/tmp/w209_znd.log
echo "--- status ---"; timeout 8 "$ZN/bin/zygiskd" status 2>&1; echo "RC=$?"

echo "########## [6] sample at t+8 ##########"
sleep 5
echo "--- procs ---"; ps -A -o PID,PPID,UID,NAME | grep -aiE 'zygisk|zn-daemon|machikado'
echo "--- status ---"; timeout 8 "$ZN/bin/zygiskd" status 2>&1; echo "RC=$?"
echo "--- /data/adb/zygisksu ---"; ls -la /data/adb/zygisksu/
echo "--- module.prop hash after launch ---"; sha256sum "$ZN/module.prop"

echo "########## [7] fresh logcat for zn-daemon ##########"
logcat -d -t 200 2>/dev/null | grep -aiE 'zn-daemon|ZygiskNext|verify|abort|write prop|inject' | tail -60

echo "===== DONE"
