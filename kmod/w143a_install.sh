#!/system/bin/sh
# 投递 A：只装模块(单独跑，避免整条链超 sushd 的 100 秒时限)。
L=/data/local/tmp/w143a.out
K=/data/local/tmp/ksud_official
ZIP=/sdcard/Download/LSPosed-2.2.0.zip
{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ====="
[ "$(md5sum $K|awk '{print $1}')" = 9cc94ff59388b09dd6d4097d25a1f83b ] || { echo ARTIFACT_WRONG; exit 1; }
echo "MNT_NS=$(readlink /proc/self/ns/mnt)"
mkdir -p /data/adb
timeout 60 $K module install "$ZIP" 2>&1 | tail -6; echo "  install_rc=$?"
echo "modules/ : $(ls /data/adb/modules 2>&1 | tr '\n' ' ')"
echo "modules_update/ : $(ls /data/adb/modules_update 2>&1 | tr '\n' ' ')"
echo "update 标记在吗: $([ -e /data/adb/modules/zygisk_lsposed/update ] && echo 有 || echo 无)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
