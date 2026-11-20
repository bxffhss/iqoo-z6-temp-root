#!/system/bin/sh
# w204_extract_modules.sh — 解压 ZygiskNext + LSPosed 模块到 /data/adb/modules/（root 腿跑）
OUT=/data/local/tmp/w204_extract.out
exec >"$OUT" 2>&1
set -x
ZIPDIR='/sdcard/Download/必备模块'
M=/data/adb/modules
mkdir -p "$M"
rm -rf "$M/zygisksu" "$M/zygisk_lsposed"
unzip -o "$ZIPDIR/Zygisk-Next-1.5.2-864-a4a72ce-relea.zip" -d "$M/zygisksu"
unzip -o "$ZIPDIR/LSPosed-v2.2.0-7854-release.zip" -d "$M/zygisk_lsposed"
chmod -R 755 "$M/zygisksu" "$M/zygisk_lsposed" 2>/dev/null
echo "=== zygisksu module.prop ==="
cat "$M/zygisksu/module.prop"
echo "=== zygisksu service.sh ==="
cat "$M/zygisksu/service.sh"
echo "=== zygisksu post-fs-data.sh ==="
cat "$M/zygisksu/post-fs-data.sh"
echo "=== zygisk_lsposed module.prop ==="
cat "$M/zygisk_lsposed/module.prop"
echo "=== zygisk_lsposed service.sh ==="
cat "$M/zygisk_lsposed/service.sh"
echo "=== zygisk_lsposed daemon ==="
cat "$M/zygisk_lsposed/daemon"
echo "=== zygisk_lsposed lspd ==="
cat "$M/zygisk_lsposed/lspd" 2>/dev/null
echo "=== zygiskd binaries present? ==="
ls -la "$M/zygisksu/bin/arm64-v8a/" 2>/dev/null
echo "===== DONE"
