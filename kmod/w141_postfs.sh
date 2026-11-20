#!/system/bin/sh
# w141_postfs.sh —— 跑官方 ksud 的 post-fs-data，看模块到底能不能挂上(唯一硬判据=mountinfo)。
#   已确认这一发的模块**没有 sepolicy.rule** ⇒ 碰不到"sepolicy apply 必硬复位"那条雷。
#   ★不跑 sepolicy/unload/uninstall/soft-reboot。
L=/data/local/tmp/w141_pfs.out
K=/data/local/tmp/ksud_official
T() { timeout 45 "$@" 2>&1; echo "  rc=$?"; }
{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ====="
echo "BEFORE mountinfo 里 modules 行数=$(grep -ac modules /proc/self/mountinfo)"
echo "BEFORE /data/adb/modules/zygisk_lsposed 内容:"; ls -l /data/adb/modules/zygisk_lsposed 2>&1 | head -6
echo "--- ksud post-fs-data ---"
T $K post-fs-data
echo "--- 之后 ---"
echo "AFTER /data/adb/modules/zygisk_lsposed:"; ls -l /data/adb/modules/zygisk_lsposed 2>&1 | head -12
echo "AFTER modules_update 还在吗: $(ls -d /data/adb/modules_update/* 2>&1 | head -3)"
echo "AFTER mountinfo modules 行数=$(grep -ac modules /proc/self/mountinfo)"
grep -a modules /proc/self/mountinfo | cut -c1-140 | head -10
echo "框架健康(shell 域): $(runcon u:r:shell:s0 service list 2>/dev/null | head -1)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
