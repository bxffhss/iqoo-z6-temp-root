#!/system/bin/sh
# w943_harvest.sh — 恢复执法**之前**最后一次 root-only 取数（全走 stdout，不建文件；§6.452：执法后连
#   /data/local/tmp 都写不出，所以这一发干脆不写）。标签纯 ASCII（adb 输出含中文会被吞成 [Binary output]）。
U() { cut -d' ' -f1 /proc/uptime; }
echo "W0 date=$(date) up=$(U) id=[$(id)] enf=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -c '^kernelsu ' /proc/modules 2>&1)"
echo "W1 allowlist dump:"
head -30 /proc/ksu_slots 2>&1 | grep -a -E "SLOTTBL|slot=|LSMHOOK|total=" | head -12
echo "W2 出生安装预算/槽位读数:"
grep -a -E "slot|birth|cap" /proc/ksu_slots 2>&1 | head -8
echo "W3 termux 进程的驱动 fd:"
for p in $(pidof com.termux 2>/dev/null); do
  echo "  pid=$p fd_ksu=$(ls -l /proc/$p/fd 2>/dev/null | grep -ac ksu_driver) ctx=$(cat /proc/$p/attr/current 2>&1)"
done
echo "W4 环里本次模块/授权相关行（模块 runner 走过 su 吗＝应为 0 条 SU0）:"
dmesg 2>/dev/null | grep -a -c "KSUBEAT SU0"
dmesg 2>/dev/null | grep -a "KSUBEAT SU0" | tail -4
echo "W5 环里 ksud/模块装载行:"
dmesg 2>/dev/null | grep -a -iE "module|throne|crown" | tail -6
echo "W6 su 层与改道落点现场:"
ls -l /product/bin/su /data/local/tmp/kd 2>&1 | cut -d' ' -f1,3,5,9
grep -a pbin /proc/self/mountinfo 2>&1 | cut -c1-90
echo "W7 /data/adb 现状(窗口中段清过):"
ls -la /data/adb 2>&1 | head -8
echo "WZ_END up=$(U)"
