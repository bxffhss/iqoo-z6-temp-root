#!/system/bin/sh
# w210_rebuild.sh — 严格按 customize.sh(SKIPUNZIP=1) 白名单重建 zygisksu 模块目录
# 目的：去掉手工 unzip 留下的多余文件，让 ZygiskNext 的 verify1 清单校验通过
# ★纯文件操作、旧目录改名备份可回滚、不碰 zygote / 内核
OUT=/data/local/tmp/w210_rebuild.out
exec >"$OUT" 2>&1
M=/data/adb/modules
ZN=$M/zygisksu
NEW=$M/.zygisksu.rebuild
BAK=$M/.zygisksu.w204bak
ZIP='/sdcard/Download/必备模块/Zygisk-Next-1.5.2-864-a4a72ce-relea.zip'

echo "########## [0] guards ##########"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) enf=$(cat /sys/fs/selinux/enforce) mod=$(grep -c kernelsu /proc/modules)"
[ -f "$ZIP" ] || { echo "ZIP_MISSING"; echo "===== DONE"; exit 1; }

echo "########## [1] build clean tree (only customize.sh whitelist) ##########"
rm -rf "$NEW"
mkdir -p "$NEW/bin" "$NEW/lib64" "$NEW/lib"
cd "$NEW" || exit 1

# 1a) 顶层脚本/配置（原样路径）
for f in module.prop post-fs-data.sh service.sh uninstall.sh mazoku cleanup.sh action.sh emulated-soft-reboot.sh sepolicy.rule; do
  unzip -o "$ZIP" "$f" -d "$NEW" >/dev/null 2>&1 || echo "EXTRACT_FAIL $f"
done
cp -f "$NEW/module.prop" "$NEW/module.prop.orig"

# 1b) webroot（排除 .sha256）
unzip -o "$ZIP" 'webroot/*' -x '*.sha256' -d "$NEW" >/dev/null 2>&1

# 1c) bin：junk paths 取对应架构，改名
unzip -oj "$ZIP" 'bin/arm64-v8a/zygiskd' -d "$NEW/bin" >/dev/null 2>&1
mv "$NEW/bin/zygiskd" "$NEW/bin/zygiskd64"
unzip -oj "$ZIP" 'bin/armeabi-v7a/zygiskd' -d "$NEW/bin" >/dev/null 2>&1
mv "$NEW/bin/zygiskd" "$NEW/bin/zygiskd32"
ln -s "./zygiskd64" "$NEW/bin/zygiskd"

# 1d) lib64 (arm64)
for f in libzygisk.so libpayload.so libzn_loader.so; do
  unzip -oj "$ZIP" "lib/arm64-v8a/$f" -d "$NEW/lib64" >/dev/null 2>&1 || echo "EXTRACT_FAIL lib64/$f"
done
# 1e) lib (32 位伴随，customize.sh 的 arm 分支只取这两个)
for f in libzygisk.so libzn_loader.so; do
  unzip -oj "$ZIP" "lib/armeabi-v7a/$f" -d "$NEW/lib" >/dev/null 2>&1 || echo "EXTRACT_FAIL lib/$f"
done

# 1f) machikado：MARCH=arm64_32（abilist32 非空）
unzip -oj "$ZIP" 'machikado.arm64_32' -d "$NEW" >/dev/null 2>&1
mv "$NEW/machikado.arm64_32" "$NEW/machikado"

echo "########## [2] permissions (set_perm_recursive 0 0 0755 0644; bin 0755) ##########"
find "$NEW" -type d -exec chmod 0755 {} \;
find "$NEW" -type f -exec chmod 0644 {} \;
chmod 0755 "$NEW/bin/zygiskd64" "$NEW/bin/zygiskd32"
chmod 0755 "$NEW/post-fs-data.sh" "$NEW/service.sh" "$NEW/uninstall.sh" "$NEW/cleanup.sh" "$NEW/action.sh" "$NEW/emulated-soft-reboot.sh"

echo "########## [3] clean tree listing (what a real install leaves) ##########"
find "$NEW" | sort
echo "--- file count ---"; find "$NEW" -type f | wc -l

echo "########## [4] swap: old -> backup, new -> zygisksu ##########"
rm -rf "$BAK"
mv "$ZN" "$BAK"
mv "$NEW" "$ZN"
echo "SWAP_DONE"
ls -la "$ZN/"

echo "########## [5] reinstall znctl symlink + clear daemon markers ##########"
mkdir -p /data/adb/ksu/bin /data/adb/zygisksu /data/adb/service.d
ln -sf "$ZN/bin/zygiskd" /data/adb/ksu/bin/znctl
cp -f "$ZN/cleanup.sh" /data/adb/service.d/.zn_cleanup.sh
chmod 0755 /data/adb/service.d/.zn_cleanup.sh
rm -f /data/adb/zygisksu/.abort_msg /data/adb/zygisksu/.injecting
echo "--- /data/adb/zygisksu ---"; ls -la /data/adb/zygisksu/

echo "########## [6] module.prop hash check (must equal .sha256 expectation) ##########"
sha256sum "$ZN/module.prop"
echo "expect: 2f8cdf9a676ed7b8cf8660abdc2302a29a2745e1e3163b74f15c7094dabfdf3d"

echo "########## [7] launch daemon detached + sample ##########"
BB=/data/adb/ksu/bin/busybox
nohup "$BB" setsid "$ZN/bin/zygiskd" daemon >/data/local/tmp/w210_znd.log 2>&1 </dev/null &
echo "SPAWN_PID=$!"
sleep 4
echo "--- procs ---"; ps -A -o PID,PPID,UID,NAME | grep -aiE 'zygisk|zn-daemon|machikado'
echo "--- daemon log ---"; cat /data/local/tmp/w210_znd.log
echo "--- status ---"; timeout 8 "$ZN/bin/zygiskd" status 2>&1; echo "RC=$?"
echo "--- fresh logcat ---"
logcat -d -t 120 2>/dev/null | grep -aiE 'zn-daemon|ZygiskNext|verify|abort|write prop|inject' | tail -40
echo "===== DONE"
