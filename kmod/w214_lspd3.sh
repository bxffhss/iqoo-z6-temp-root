#!/system/bin/sh
# w214_lspd3.sh — 严格白名单重建 zygisk_lsposed + 正确 SELinux 标签 + 双 fork 起 lspd
# ★纯文件操作、旧目录备份可回滚、不碰 zygote / 内核
OUT=/data/local/tmp/w214_lspd3.out
exec >"$OUT" 2>&1
M=/data/adb/modules
LP=$M/zygisk_lsposed
NEW=$M/.zygisk_lsposed.rebuild
BAK=$M/.zygisk_lsposed.w204bak
ZIP='/sdcard/Download/必备模块/LSPosed-v2.2.0-7854-release.zip'
BB=/data/adb/ksu/bin/busybox

echo "########## [0] guards ##########"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) enf=$(cat /sys/fs/selinux/enforce) mod=$(grep -c kernelsu /proc/modules)"
[ -f "$ZIP" ] || { echo "ZIP_MISSING"; echo "===== DONE"; exit 1; }
# 精确杀旧 lspd（不用 pkill -f，避免自杀）
for p in $(pidof lspd 2>/dev/null); do kill -9 "$p" 2>/dev/null; done

echo "########## [1] rebuild strict whitelist (customize.sh SKIPUNZIP=1) ##########"
rm -rf "$NEW"
mkdir -p "$NEW/zygisk" "$NEW/lib" "$NEW/bin"
cd "$NEW" || exit 1
# 顶层文件（原样路径）
for f in module.prop action.sh service.sh emulated-soft-reboot.sh uninstall.sh sepolicy.rule zn_modules.txt framework.dex daemon.apk daemon lspd manager.apk mazoku package.pb launcher.png; do
  unzip -o "$ZIP" "$f" -d "$NEW" >/dev/null 2>&1 || echo "EXTRACT_FAIL $f"
done
# machikado.arm64
unzip -oj "$ZIP" 'machikado.arm64' -d "$NEW" >/dev/null 2>&1
mv "$NEW/machikado.arm64" "$NEW/machikado"
# zygisk/*.so = libframework.so
unzip -oj "$ZIP" 'lib/arm64-v8a/libframework.so' -d "$NEW/zygisk" >/dev/null 2>&1
mv "$NEW/zygisk/libframework.so" "$NEW/zygisk/arm64-v8a.so"
unzip -oj "$ZIP" 'lib/armeabi-v7a/libframework.so' -d "$NEW/zygisk" >/dev/null 2>&1
mv "$NEW/zygisk/libframework.so" "$NEW/zygisk/armeabi-v7a.so"
# lib/libpreload*.so
unzip -oj "$ZIP" 'lib/arm64-v8a/libpreload.so' -d "$NEW/lib" >/dev/null 2>&1
mv "$NEW/lib/libpreload.so" "$NEW/lib/libpreload64.so"
unzip -oj "$ZIP" 'lib/armeabi-v7a/libpreload.so' -d "$NEW/lib" >/dev/null 2>&1
mv "$NEW/lib/libpreload.so" "$NEW/lib/libpreload32.so"
# bin/dex2oat{64,32}
unzip -oj "$ZIP" 'bin/arm64-v8a/dex2oat' -d "$NEW/bin" >/dev/null 2>&1
mv "$NEW/bin/dex2oat" "$NEW/bin/dex2oat64"
unzip -oj "$ZIP" 'bin/armeabi-v7a/dex2oat' -d "$NEW/bin" >/dev/null 2>&1
mv "$NEW/bin/dex2oat" "$NEW/bin/dex2oat32"

echo "########## [2] permissions + SELinux labels (customize.sh) ##########"
find "$NEW" -type d -exec chmod 0755 {} \;
find "$NEW" -type f -exec chmod 0644 {} \;
chmod 0755 "$NEW/bin/dex2oat64" "$NEW/bin/dex2oat32"
chmod 0744 "$NEW/daemon" "$NEW/lspd"
# ★关键：dex2oat 需要 dex2oat_exec 域，否则 bind mount 后 ART 拒绝/异常
chcon u:object_r:dex2oat_exec:s0 "$NEW/bin/dex2oat64" 2>&1; echo "CHCON64_RC=$?"
chcon u:object_r:dex2oat_exec:s0 "$NEW/bin/dex2oat32" 2>&1; echo "CHCON32_RC=$?"
echo "--- labels ---"; ls -Z "$NEW/bin/" 2>&1

echo "########## [3] clean tree listing ##########"
find "$NEW" | sort
echo "file_count=$(find "$NEW" -type f | wc -l)"

echo "########## [4] swap ##########"
rm -rf "$BAK"
mv "$LP" "$BAK"
mv "$NEW" "$LP"
echo "SWAP_DONE"

echo "########## [5] lspd launch (double-fork, fully detached, no wait) ##########"
mkdir -p /data/adb/lspd
: > /data/adb/lspd/skip_online_request
chmod 0666 /data/adb/lspd/skip_online_request
rm -f /data/local/tmp/daemon.apk /data/local/tmp/manager.apk
# 双 fork：子 shell 立即退出，孙进程被 init 收养；所有 fd 断开
( setsid runcon u:r:system_server:s0 sh -c "cd $LP && exec ./daemon --force" >/data/local/tmp/w214_lspd.log 2>&1 </dev/null & ) 
echo "LAUNCH_ISSUED"

echo "########## [6] samples ##########"
for t in 1 2 3 4; do
  sleep 4
  echo "t+$((t*4))s lspd=[$(pidof lspd)]"
done
echo "--- procs ---"; ps -A -o PID,PPID,UID,NAME | grep -aiE 'lspd|app_process'
echo "--- wrapper log ---"; cat /data/local/tmp/w214_lspd.log

echo "########## [7] fresh LSPosed logcat ##########"
logcat -d -t 250 2>/dev/null | grep -aiE 'LSPosed|lspd|LSPosedService|dex2oat|FATAL' | tail -40

echo "########## [8] zn status + window ##########"
timeout 8 "$M/zygisksu/bin/zygiskd" status 2>&1 | grep -aE 'version:|zygote_states|inject_state|root_status|modules'
echo "boot_completed=$(getprop sys.boot_completed) zygote64_start=$(awk '{print $22}' /proc/$(pidof zygote64)/stat)"
echo "===== DONE"
