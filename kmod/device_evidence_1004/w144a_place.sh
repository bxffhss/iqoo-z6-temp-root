#!/system/bin/sh
# 投递 A2：把 ksud **放到模块脚本硬编码的那个路径**上，再装模块。
#   依据：strings 里模块自己的脚本写的是 `/data/adb/ksud sepolicy check`、
#   `/data/adb/ksud feature check` ⇒ /data/adb/ksud 不存在时这些检测全失败 ⇒ 可能因此跳过挂载。
L=/data/local/tmp/w144a.out; K=/data/adb/ksud; ZIP=/sdcard/Download/LSPosed-2.2.0.zip
{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ====="
mkdir -p /data/adb
cp /data/local/tmp/ksud_official $K && chmod 755 $K && echo "PLACED md5=$(md5sum $K|awk '{print $1}') size=$(stat -c %s $K)"
timeout 50 $K module install "$ZIP" 2>&1 | tail -3; echo "  install_rc=$?"
echo "modules/: $(ls /data/adb/modules 2>&1|tr '\n' ' ')"
echo "update 标记: $([ -e /data/adb/modules/zygisk_lsposed/update ] && echo 有 || echo 无)"
echo "mountinfo modules 行数=$(grep -ac modules /proc/self/mountinfo)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
