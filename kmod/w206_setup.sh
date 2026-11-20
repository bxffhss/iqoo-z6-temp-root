#!/system/bin/sh
# w206_setup.sh — 复现两个模块 customize.sh 的 arch 选择 + 清旧残留 + 起 zygiskd daemon + 读 status
# ★不碰 zygote、不跑 ksud post-fs-data（Z5 硬警告：内核卡死+硬复位）
OUT=/data/local/tmp/w206_setup.out
exec >"$OUT" 2>&1
M=/data/adb/modules
ZN=$M/zygisksu
LP=$M/zygisk_lsposed

echo "########## [A] ZygiskNext arch select: arm64 primary + armeabi-v7a companion ##########"
mkdir -p "$ZN/bin" "$ZN/lib64" "$ZN/lib" /data/adb/zygisksu /data/adb/service.d /data/adb/ksu/bin
cp -f "$ZN/bin/arm64-v8a/zygiskd"          "$ZN/bin/zygiskd64"
cp -f "$ZN/bin/armeabi-v7a/zygiskd"        "$ZN/bin/zygiskd32"
chmod 0755 "$ZN/bin/zygiskd64" "$ZN/bin/zygiskd32"
ln -sf "./zygiskd64" "$ZN/bin/zygiskd"
cp -f "$ZN/lib/arm64-v8a/libzygisk.so"     "$ZN/lib64/libzygisk.so"
cp -f "$ZN/lib/arm64-v8a/libpayload.so"    "$ZN/lib64/libpayload.so"
cp -f "$ZN/lib/arm64-v8a/libzn_loader.so"  "$ZN/lib64/libzn_loader.so"
cp -f "$ZN/lib/armeabi-v7a/libzygisk.so"   "$ZN/lib/libzygisk.so"
cp -f "$ZN/lib/armeabi-v7a/libzn_loader.so" "$ZN/lib/libzn_loader.so"
chmod 0644 "$ZN/lib64/"*.so "$ZN/lib/"*.so
cp -f "$ZN/machikado.arm64_32" "$ZN/machikado"
cp -f "$ZN/module.prop" "$ZN/module.prop.orig"
cp -f "$ZN/cleanup.sh" /data/adb/service.d/.zn_cleanup.sh
chmod 0755 /data/adb/service.d/.zn_cleanup.sh
ln -sf "$ZN/bin/zygiskd" /data/adb/ksu/bin/znctl
echo "A_DONE"

echo "########## [B] LSPosed arch select ##########"
mkdir -p "$LP/zygisk" "$LP/lib" "$LP/bin"
cp -f "$LP/machikado.arm64"                    "$LP/machikado"
cp -f "$LP/lib/arm64-v8a/libframework.so"      "$LP/zygisk/arm64-v8a.so"
cp -f "$LP/lib/armeabi-v7a/libframework.so"    "$LP/zygisk/armeabi-v7a.so"
cp -f "$LP/lib/arm64-v8a/libpreload.so"        "$LP/lib/libpreload64.so"
cp -f "$LP/lib/armeabi-v7a/libpreload.so"      "$LP/lib/libpreload32.so"
cp -f "$LP/bin/arm64-v8a/dex2oat"              "$LP/bin/dex2oat64"
cp -f "$LP/bin/armeabi-v7a/dex2oat"            "$LP/bin/dex2oat32"
chmod 0755 "$LP/bin/dex2oat64" "$LP/bin/dex2oat32" "$LP/daemon" "$LP/lspd"
chmod 0644 "$LP/zygisk/"*.so "$LP/lib/"*.so
echo "B_DONE"

echo "########## [C] clear 11-13 stale daemon state (post-fs-data.sh semantics) ##########"
echo "--- before ---"
ls -la /data/adb/zygisksu/
rm -f /data/adb/zygisksu/.abort_msg
mv /data/adb/zygisksu/znctx       /data/adb/zygisksu/znctx.old       2>/dev/null
mv /data/adb/zygisksu/modules_info /data/adb/zygisksu/modules_info.old 2>/dev/null
echo "--- after ---"
ls -la /data/adb/zygisksu/

echo "########## [D] LSPosed license check (no network on device) ##########"
ls -la /data/adb/lspd/
echo "--- license.pb ---"; ls -la /data/adb/lspd/license.pb 2>&1
echo "--- config dir ---"; ls -la /data/adb/lspd/config/ 2>&1
echo "--- skip_online_request ---"; ls -la /data/adb/lspd/skip_online_request 2>&1

echo "########## [E] layout readback ##########"
echo "--- ZN bin ---";      ls -la "$ZN/bin/"
echo "--- ZN lib64 ---";    ls -la "$ZN/lib64/"
echo "--- ZN lib ---";      ls -la "$ZN/lib/"
echo "--- ZN machikado ---"; ls -la "$ZN/machikado"
echo "--- LP zygisk ---";   ls -la "$LP/zygisk/"
echo "--- LP lib ---";      ls -la "$LP/lib/"
echo "--- znctl symlink ---"; ls -la /data/adb/ksu/bin/znctl

echo "########## [F] start zygiskd daemon ##########"
nohup "$ZN/bin/zygiskd" daemon >/data/local/tmp/w206_znd.log 2>&1 &
echo "SPAWN_PID=$!"
sleep 5
echo "--- daemon log ---"
cat /data/local/tmp/w206_znd.log
echo "--- related processes ---"
ps -A -o PID,PPID,UID,NAME | grep -aiE 'zygiskd|zn-daemon|lspd|machikado'
echo "--- status (timeout 8) ---"
timeout 8 "$ZN/bin/zygiskd" status 2>&1; echo "STATUS_RC=$?"
echo "--- /data/adb/zygisksu after start ---"
ls -la /data/adb/zygisksu/
echo "===== DONE"
