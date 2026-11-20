#!/system/bin/sh
# w145_late.sh —— 试 `ksud late-load`(子命令描述里"执行 late-load 阶段脚本"就是挂载该在的地方)。
#   安全性：它会先尝试 insmod kernelsu.ko，但我们的 ko 已加载且同名 ⇒ 只会 EEXIST 失败，不会双加载。
#   ★仍然不碰 sepolicy patch / unload / uninstall / soft-reboot。
L=/data/local/tmp/w145_late.out; K=/data/adb/ksud
MC() { grep -ac modules /proc/self/mountinfo; }
{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ====="
echo "BEFORE: mod=$(grep -c kernelsu /proc/modules) modules行数=$(MC)"
echo "--- 它会去哪儿找 ko(先看它抱怨什么) ---"
ls -l /data/adb/ksud.ko /data/adb/kpatch 2>&1 | head -3
echo "--- ksud late-load ---"
timeout 45 $K late-load >/data/local/tmp/w145_lr.txt 2>&1; echo "  rc=$?"
head -20 /data/local/tmp/w145_lr.txt | sed 's/^/    /'
echo "--- 之后 ---"
echo "AFTER: mod=$(grep -c kernelsu /proc/modules) modules行数=$(MC)"
grep -aE "modules| /system" /proc/self/mountinfo | cut -c1-140 | head -10
echo "框架=$(runcon u:r:shell:s0 service list 2>/dev/null|head -1) enforce=$(cat /sys/fs/selinux/enforce)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
