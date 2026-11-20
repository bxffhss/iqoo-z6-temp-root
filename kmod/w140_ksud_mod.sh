#!/system/bin/sh
# w140_ksud_mod.sh —— 只问一件事：官方 ksud 能不能驱动"模块"这条功能。
#   前提已一手确认：root 侧 SECCOMP=0 ⇒ ksud 的 reboot(142) 超级调用传输口在这里是通的
#   （第 34 发它在 app 域被 SIGSYS 打死）。
#   ★不跑 sepolicy patch/apply(本机必硬复位)、不跑 unload/uninstall、不跑 soft-reboot。
L=/data/local/tmp/w140_mod.out
K=/data/local/tmp/ksud_official
ZIP=/sdcard/Download/LSPosed-2.2.0.zip
NEED=9cc94ff59388b09dd6d4097d25a1f83b
T() { timeout 18 "$@" 2>&1; echo "  rc=$?"; }
{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ====="
[ "$(md5sum $K | awk '{print $1}')" = "$NEED" ] || { echo "ARTIFACT_WRONG"; exit 1; }
chmod 755 $K; mkdir -p /data/adb/modules /data/adb/ksu/bin
echo "--- [1] 它能不能看见内核(=驱动 fd 通不通) ---"
echo "  [kernel interface]"; T $K kernel
echo "  [feature check su_compat]"; T $K feature check su_compat
echo "  [feature check kernel_umount]"; T $K feature check kernel_umount
echo "  [module ls]"; T $K module ls
echo "--- [2] 装模块 ---"
echo "  zip: $(ls -l $ZIP 2>&1 | tail -1)"
echo "  [module install]"; T $K module install "$ZIP"
echo "  装完 /data/adb/modules:"; ls -l /data/adb/modules 2>&1 | head -6
echo "--- [3] 模块有没有真的挂上去(唯一硬判据) ---"
grep -a "modules" /proc/self/mountinfo | cut -c1-140 | head -6
echo "MOUNT_COUNT=$(grep -ac 'modules' /proc/self/mountinfo)"
echo "--- [4] late-load 的用法(只读 --help，不执行) ---"
T $K late-load --help
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
