#!/system/bin/sh
# w230_rebuild_all.sh — 收窗+重开后模块目录被清 ⇒ 严格按 customize.sh 白名单重建两模块
# 复用 w210/w214 已验证逻辑；★本脚本不启动任何 daemon（交给 z6_stage4.sh 的 start_zn/start_lspd）
OUT=/data/local/tmp/w230_rebuild_all.out
exec >"$OUT" 2>&1
M=/data/adb/modules
ZN=$M/zygisksu
LP=$M/zygisk_lsposed
ZNZIP='/sdcard/Download/必备模块/Zygisk-Next-1.5.2-864-a4a72ce-relea.zip'
LPZIP='/sdcard/Download/必备模块/LSPosed-v2.2.0-7854-release.zip'
BB=/data/adb/ksu/bin/busybox

echo "ts=$(date +%Y-%m-%dT%H:%M:%S) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null)"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) mod=$(grep -c kernelsu /proc/modules) enf=$(cat /sys/fs/selinux/enforce)"
echo "--- /data/adb 现状 ---"
ls -la /data/adb/ 2>&1

echo "########## [0] zip 存在性 ##########"
ls -la "$ZNZIP" "$LPZIP" 2>&1
[ -f "$ZNZIP" ] && [ -f "$LPZIP" ] || { echo "### ABORT zip missing"; echo "===== DONE"; exit 1; }

echo "########## [1] ZygiskNext 严格白名单 (SKIPUNZIP=1, MARCH=arm64_32) ##########"
rm -rf "$ZN"
mkdir -p "$ZN/bin" "$ZN/lib64" "$ZN/lib" /data/adb/zygisksu /data/adb/service.d /data/adb/ksu/bin
cd "$ZN" || exit 1
for f in module.prop post-fs-data.sh service.sh uninstall.sh mazoku cleanup.sh action.sh emulated-soft-reboot.sh sepolicy.rule; do
  unzip -o "$ZNZIP" "$f" -d "$ZN" >/dev/null 2>&1 || echo "FAIL $f"
done
cp -f "$ZN/module.prop" "$ZN/module.prop.orig"
unzip -o "$ZNZIP" 'webroot/*' -x '*.sha256' -d "$ZN" >/dev/null 2>&1
unzip -oj "$ZNZIP" 'bin/arm64-v8a/zygiskd' -d "$ZN/bin" >/dev/null 2>&1 && mv "$ZN/bin/zygiskd" "$ZN/bin/zygiskd64"
unzip -oj "$ZNZIP" 'bin/armeabi-v7a/zygiskd' -d "$ZN/bin" >/dev/null 2>&1 && mv "$ZN/bin/zygiskd" "$ZN/bin/zygiskd32"
ln -sf "./zygiskd64" "$ZN/bin/zygiskd"
for f in libzygisk.so libpayload.so libzn_loader.so; do
  unzip -oj "$ZNZIP" "lib/arm64-v8a/$f" -d "$ZN/lib64" >/dev/null 2>&1 || echo "FAIL lib64/$f"
done
for f in libzygisk.so libzn_loader.so; do
  unzip -oj "$ZNZIP" "lib/armeabi-v7a/$f" -d "$ZN/lib" >/dev/null 2>&1 || echo "FAIL lib/$f"
done
unzip -oj "$ZNZIP" 'machikado.arm64_32' -d "$ZN" >/dev/null 2>&1 && mv "$ZN/machikado.arm64_32" "$ZN/machikado"
find "$ZN" -type d -exec chmod 0755 {} \;
find "$ZN" -type f -exec chmod 0644 {} \;
chmod 0755 "$ZN/bin/zygiskd64" "$ZN/bin/zygiskd32" "$ZN"/*.sh /data/adb/service.d/.zn_cleanup.sh 2>/dev/null
cp -f "$ZN/cleanup.sh" /data/adb/service.d/.zn_cleanup.sh; chmod 0755 /data/adb/service.d/.zn_cleanup.sh
ln -sf "$ZN/bin/zygiskd" /data/adb/ksu/bin/znctl
echo "ZN files=$(find "$ZN" -type f | wc -l) zygiskd64=$(ls -l "$ZN/bin/zygiskd64" 2>&1 | awk '{print $5}')"
echo "ZN module.prop hash=$(sha256sum "$ZN/module.prop" | awk '{print $1}')"

echo "########## [2] LSPosed 严格白名单 ##########"
rm -rf "$LP"
mkdir -p "$LP/zygisk" "$LP/lib" "$LP/bin"
cd "$LP" || exit 1
for f in module.prop action.sh service.sh emulated-soft-reboot.sh uninstall.sh sepolicy.rule zn_modules.txt framework.dex daemon.apk daemon lspd manager.apk mazoku package.pb launcher.png; do
  unzip -o "$LPZIP" "$f" -d "$LP" >/dev/null 2>&1 || echo "FAIL $f"
done
unzip -oj "$LPZIP" 'machikado.arm64' -d "$LP" >/dev/null 2>&1 && mv "$LP/machikado.arm64" "$LP/machikado"
unzip -oj "$LPZIP" 'lib/arm64-v8a/libframework.so' -d "$LP/zygisk" >/dev/null 2>&1 && mv "$LP/zygisk/libframework.so" "$LP/zygisk/arm64-v8a.so"
unzip -oj "$LPZIP" 'lib/armeabi-v7a/libframework.so' -d "$LP/zygisk" >/dev/null 2>&1 && mv "$LP/zygisk/libframework.so" "$LP/zygisk/armeabi-v7a.so"
unzip -oj "$LPZIP" 'lib/arm64-v8a/libpreload.so' -d "$LP/lib" >/dev/null 2>&1 && mv "$LP/lib/libpreload.so" "$LP/lib/libpreload64.so"
unzip -oj "$LPZIP" 'lib/armeabi-v7a/libpreload.so' -d "$LP/lib" >/dev/null 2>&1 && mv "$LP/lib/libpreload.so" "$LP/lib/libpreload32.so"
unzip -oj "$LPZIP" 'bin/arm64-v8a/dex2oat' -d "$LP/bin" >/dev/null 2>&1 && mv "$LP/bin/dex2oat" "$LP/bin/dex2oat64"
unzip -oj "$LPZIP" 'bin/armeabi-v7a/dex2oat' -d "$LP/bin" >/dev/null 2>&1 && mv "$LP/bin/dex2oat" "$LP/bin/dex2oat32"
find "$LP" -type d -exec chmod 0755 {} \;
find "$LP" -type f -exec chmod 0644 {} \;
chmod 0755 "$LP/bin/dex2oat64" "$LP/bin/dex2oat32"
chmod 0744 "$LP/daemon" "$LP/lspd"
chcon u:object_r:dex2oat_exec:s0 "$LP/bin/dex2oat64" 2>&1; echo "CHCON64_RC=$?"
chcon u:object_r:dex2oat_exec:s0 "$LP/bin/dex2oat32" 2>&1; echo "CHCON32_RC=$?"
echo "LP files=$(find "$LP" -type f | wc -l)"

echo "########## [2.5] ★★先补 /data/adb/ksud（必须在起 ZN daemon 之前！） ##########"
# 第三发根因：收窗删 ksud；ZN daemon 启动时一次性判 root 实现，缓存成 ❌None 后不再重检
#   ⇒ GetRootImpl permission denied、注入不发生。第四发必须先补 ksud 再起 daemon。
# ★第四发：优先用**设备原版**(4,892,712 B / md5 de059ed8…，第一发成功时就在 /data/adb/ksud 的那份)，
#   第三发误用了 6,286,568 B 的 ksud_official（另一个构建）。
KSUD_SRC=""
for c in /data/local/tmp/w234_ksud_orig /data/local/tmp/w234_ksud; do
  [ -f "$c" ] && { KSUD_SRC="$c"; break; }
done
if [ -n "$KSUD_SRC" ]; then
  cp -f "$KSUD_SRC" /data/adb/ksud
  chmod 0755 /data/adb/ksud
  echo "KSUD_OK src=$KSUD_SRC md5=$(md5sum /data/adb/ksud | awk '{print $1}') size=$(wc -c < /data/adb/ksud)"
else
  echo "### WARN: ksud 源文件都缺 ⇒ 主机侧先 adb push kmod/_tmp_ksud_from_dev /data/local/tmp/w234_ksud_orig"
fi

echo "########## [3] 清 daemon 状态标记 + 读回 ##########"
rm -f /data/adb/zygisksu/.abort_msg /data/adb/zygisksu/.injecting /data/adb/zygisksu/znctx /data/adb/zygisksu/modules_info
mkdir -p /data/adb/lspd; : > /data/adb/lspd/skip_online_request; chmod 0666 /data/adb/lspd/skip_online_request
echo "--- ZN top ---"; ls -la "$ZN/" | head -25
echo "--- ZN bin ---"; ls -la "$ZN/bin/"
echo "--- LP zygisk ---"; ls -la "$LP/zygisk/"
echo "--- labels ---"; ls -Z "$LP/bin/" 2>&1
echo "--- probe2 ---"; md5sum /data/local/tmp/probe2.jar 2>&1
echo "--- z6 scripts ---"; ls -la /data/local/tmp/z6_stage4.sh /data/local/tmp/z6_launch.sh 2>&1
echo "===== DONE"
