#!/system/bin/sh
# w912_appleg.sh — §6.449 的 L2 腿（#209）：同一个 app 里跑两条 su，一条由"脚本 shell 自己"执行、
# 一条由"它 fork 的子 shell"执行，两条都落带 up= 的标记，好和整环快照里的 SU0/SU1d/SU4 成对。
# ★只在 Permissive 段跑（执法态读不到 dmesg，这条腿就没有证人可读＝§6.447③）。
HA=/data/data/com.termux/files/home
A=$HA/w912.out

{
  echo "W912 BEGIN date=$(date) up=$(cut -d' ' -f1 /proc/uptime 2>&1)"
  echo "W912 enf=[$(cat /sys/fs/selinux/enforce 2>&1)]"
  echo "W912 mod=$(grep -c '^kernelsu ' /proc/modules 2>&1) id0=[$(id)]"
} > $A 2>&1

if [ "$(grep -c '^kernelsu ' /proc/modules 2>/dev/null)" != "1" ]; then
  echo "W912 SKIP: mod!=1 ⇒ 未测(不是掉牌、不是判负)" >> $A 2>&1
  exit 0
fi

echo "D2_BEGIN up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "D2 rc=$?" >> $A 2>&1

echo "D3_BEGIN up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/sh -c '/system/bin/su -c id' >> $A 2>&1
echo "D3 rc=$?" >> $A 2>&1

echo "D4_BEGIN(再来一条深度2，作同窗正对照) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "D4 rc=$?" >> $A 2>&1

echo "W912 END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
