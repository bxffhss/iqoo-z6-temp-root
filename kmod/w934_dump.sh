#!/system/bin/sh
# w934_dump.sh — 目标③ 的现场读数，**改成走 stdout**（不建文件）。
# 为什么不能用文件：本发一手两条都红——root 在 shell 域写不出 /data/local/tmp（0771 靠 CAP_DAC_OVERRIDE，
# 而 shell 域 capability 零条）；也写不出 /data/adb（chmod rc=1＝adb_data_file 那组规则真缺，§6.447 的
# 那条 delta 名单里就有它）。⇒ 执法后 root 腿的读数只能走管道回 PC。
# ★标签一律 ASCII：adb 输出含中文会被我自己的工具吞成 [Binary output]。
# ★只读；不碰 modules 内容；绝不跑 `ksud post-fs-data`（Z5 包明文＝内核卡死＋硬复位，与我们 §6.322 同墙）。
echo "S0 date=$(date) up=$(cut -d' ' -f1 /proc/uptime) id=[$(id)]"
echo "S1 enf=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -c '^kernelsu ' /proc/modules 2>&1)"
echo "S2 ls /data/adb:"
ls -la /data/adb 2>&1
echo "S3 ls /data/adb/modules:"
ls -la /data/adb/modules 2>&1
echo "S4 modules_update tree:"
ls -laR /data/adb/modules_update 2>&1 | head -24
echo "S5 per-module props:"
for d in /data/adb/modules/*; do
  [ -d "$d" ] || continue
  echo "MOD=[$d]"
  cat "$d/module.prop" 2>&1
  ls -l "$d" 2>&1 | head -10
done
echo "S6 procs:"
ps -A -o PID,PPID,USER,NAME 2>&1 | grep -a -E "ksud|shd" | grep -a -v grep
echo "S7 mountinfo module-ish lines:"
grep -a -E "modules|adb/ksu" /proc/self/mountinfo 2>&1 | head -12
echo "S8 ksu dirs:"
ls -ld /data/adb/ksu /data/adb/ksud /data/adb/ksu/lib 2>&1
echo "SZ_END date=$(date) up=$(cut -d' ' -f1 /proc/uptime)"
