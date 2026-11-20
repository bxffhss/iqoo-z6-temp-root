#!/system/bin/sh
# w234_restore.sh — 轻量补回被 KSU boot 后整理清掉的模块文件
# ★不杀 zn-daemon(30397，已持有 lsposed so 的 fd)、不清 /data/adb/zygisksu 状态目录
# ★严格按 customize.sh 白名单（与 w230 一致），避免 ZN verify1 再拒
OUT=/data/local/tmp/w234_restore.out
exec >"$OUT" 2>&1
M=/data/adb/modules
ZN=$M/zygisksu
LP=$M/zygisk_lsposed
ZNZIP='/sdcard/Download/必备模块/Zygisk-Next-1.5.2-864-a4a72ce-relea.zip'
LPZIP='/sdcard/Download/必备模块/LSPosed-v2.2.0-7854-release.zip'
U=/system/bin/unzip
echo "ts=$(date +%Y-%m-%dT%H:%M:%S) uid=$(id -u)"
echo "zndaemon_before=[$(pidof zn-daemon)]"

echo "########## [1] ZN 白名单 ##########"
mkdir -p "$ZN/bin" "$ZN/lib64" "$ZN/lib"
for f in module.prop post-fs-data.sh service.sh uninstall.sh mazoku cleanup.sh action.sh emulated-soft-reboot.sh sepolicy.rule; do
  "$U" -o "$ZNZIP" "$f" -d "$ZN" >/dev/null 2>&1 || echo "FAIL $f"
done
cp -f "$ZN/module.prop" "$ZN/module.prop.orig"
"$U" -o "$ZNZIP" 'webroot/*' -x '*.sha256' -d "$ZN" >/dev/null 2>&1
"$U" -oj "$ZNZIP" 'bin/arm64-v8a/zygiskd' -d "$ZN/bin" >/dev/null 2>&1 && mv "$ZN/bin/zygiskd" "$ZN/bin/zygiskd64"
"$U" -oj "$ZNZIP" 'bin/armeabi-v7a/zygiskd' -d "$ZN/bin" >/dev/null 2>&1 && mv "$ZN/bin/zygiskd" "$ZN/bin/zygiskd32"
ln -sf "./zygiskd64" "$ZN/bin/zygiskd"
for f in libzygisk.so libpayload.so libzn_loader.so; do "$U" -oj "$ZNZIP" "lib/arm64-v8a/$f" -d "$ZN/lib64" >/dev/null 2>&1 || echo "FAIL lib64/$f"; done
for f in libzygisk.so libzn_loader.so; do "$U" -oj "$ZNZIP" "lib/armeabi-v7a/$f" -d "$ZN/lib" >/dev/null 2>&1 || echo "FAIL lib/$f"; done
"$U" -oj "$ZNZIP" 'machikado.arm64_32' -d "$ZN" >/dev/null 2>&1 && mv "$ZN/machikado.arm64_32" "$ZN/machikado"
find "$ZN" -type d -exec chmod 0755 {} \;
find "$ZN" -type f -exec chmod 0644 {} \;
chmod 0755 "$ZN/bin/zygiskd64" "$ZN/bin/zygiskd32" "$ZN"/*.sh 2>/dev/null
mkdir -p /data/adb/ksu/bin; ln -sf "$ZN/bin/zygiskd" /data/adb/ksu/bin/znctl
echo "ZN files=$(find "$ZN" -type f | wc -l) hash=$(sha256sum "$ZN/module.prop" | awk '{print $1}')"

echo "########## [2] LP 白名单 ##########"
mkdir -p "$LP/zygisk" "$LP/lib" "$LP/bin"
for f in module.prop action.sh service.sh emulated-soft-reboot.sh uninstall.sh sepolicy.rule zn_modules.txt framework.dex daemon.apk daemon lspd manager.apk mazoku package.pb launcher.png; do
  "$U" -o "$LPZIP" "$f" -d "$LP" >/dev/null 2>&1 || echo "FAIL $f"
done
"$U" -oj "$LPZIP" 'machikado.arm64' -d "$LP" >/dev/null 2>&1 && mv "$LP/machikado.arm64" "$LP/machikado"
"$U" -oj "$LPZIP" 'lib/arm64-v8a/libframework.so' -d "$LP/zygisk" >/dev/null 2>&1 && mv "$LP/zygisk/libframework.so" "$LP/zygisk/arm64-v8a.so"
"$U" -oj "$LPZIP" 'lib/armeabi-v7a/libframework.so' -d "$LP/zygisk" >/dev/null 2>&1 && mv "$LP/zygisk/libframework.so" "$LP/zygisk/armeabi-v7a.so"
"$U" -oj "$LPZIP" 'lib/arm64-v8a/libpreload.so' -d "$LP/lib" >/dev/null 2>&1 && mv "$LP/lib/libpreload.so" "$LP/lib/libpreload64.so"
"$U" -oj "$LPZIP" 'lib/armeabi-v7a/libpreload.so' -d "$LP/lib" >/dev/null 2>&1 && mv "$LP/lib/libpreload.so" "$LP/lib/libpreload32.so"
"$U" -oj "$LPZIP" 'bin/arm64-v8a/dex2oat' -d "$LP/bin" >/dev/null 2>&1 && mv "$LP/bin/dex2oat" "$LP/bin/dex2oat64"
"$U" -oj "$LPZIP" 'bin/armeabi-v7a/dex2oat' -d "$LP/bin" >/dev/null 2>&1 && mv "$LP/bin/dex2oat" "$LP/bin/dex2oat32"
find "$LP" -type d -exec chmod 0755 {} \;
find "$LP" -type f -exec chmod 0644 {} \;
chmod 0755 "$LP/bin/dex2oat64" "$LP/bin/dex2oat32"; chmod 0744 "$LP/daemon" "$LP/lspd"
chcon u:object_r:dex2oat_exec:s0 "$LP/bin/dex2oat64" 2>&1; echo "CHCON64=$?"
chcon u:object_r:dex2oat_exec:s0 "$LP/bin/dex2oat32" 2>&1; echo "CHCON32=$?"
echo "LP files=$(find "$LP" -type f | wc -l)"

echo "########## [3] 补 /data/adb/ksud（ZN 判 root 实现用；收窗会删） ##########"
if [ -f /data/local/tmp/w234_ksud ]; then
  cp -f /data/local/tmp/w234_ksud /data/adb/ksud && chmod 0755 /data/adb/ksud && echo "KSUD_OK $(md5sum /data/adb/ksud | awk '{print $1}')"
else
  echo "KSUD_SRC_MISSING (non-fatal)"
fi

echo "########## [4] 读回：daemon 仍在 + 关键件齐 ##########"
echo "zndaemon_after=[$(pidof zn-daemon)]"
echo "zd=$(ls -l $ZN/bin/zygiskd 2>&1 | awk '{print $5}') lspd_daemon=$(ls -l $LP/daemon 2>&1 | awk '{print $5}')"
echo "--- znctl status ---"
/system/bin/timeout 8 "$ZN/bin/zygiskd" status 2>&1 | grep -aE 'version:|inject_state|zygote_states|root_status|modules|err:'
echo "===== DONE"
