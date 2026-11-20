#!/system/bin/sh
# w993_shot63_leg.sh —— 第 63 发开窗后的第一段 root 腿（Permissive 段；B2 之前先把地基复证一遍）。
# 三件事各自带独立读数，任何一件红都不许把别件的读数当"过了"：
#   S1 删掉 §6.460 那个 MLS 挡 unlink 的尾巴；
#   S2 现取活策略导出（这就是 #216 的底料，也当 B2 的"设备自己那份"参照）；
#   S3 用**已在设备上验证过的** arm64 往返工具(w976_arm)对 S2 那份跑一次空 delta ⇒ "工具没坏"的复证。
# ★本腿不碰 /sys/fs/selinux/load、不翻执法。
L=/data/local/tmp/w993_shot63.out
: > $L
echo "BEGIN up=$(cat /proc/uptime) enforce=$(cat /sys/fs/selinux/enforce 2>&1)" >> $L
echo "whoami=$(id 2>&1)" >> $L

echo "--- S1) 删 MLS_Q_cats 尾巴" >> $L
Q=/data/data/com.termux/files/MLS_Q_cats
echo "S1_before=$(ls -dZ $Q 2>&1 | tr -s ' ')" >> $L
rm -rf $Q
echo "S1_rm_rc=$?" >> $L
if ls -d $Q >/dev/null 2>&1; then
  echo "S1_after=还在(没删掉)" >> $L
  ls -dZ $Q >> $L 2>&1
else
  echo "S1_after=已不存在(判正)" >> $L
fi

echo "--- S2) 现取活策略导出" >> $L
P=/data/local/tmp/pol.pre_shot63
/system/bin/cat /sys/fs/selinux/policy > $P
echo "S2_cat_rc=$?" >> $L
echo "S2_bytes=$(wc -c < $P 2>&1)" >> $L
echo "S2_md5=$(md5sum $P 2>&1)" >> $L
echo "S2_magic=$(od -An -tx1 -N4 $P 2>&1 | tr -d ' \n')" >> $L

echo "--- S3) w976_arm 空 delta 往返（工具没坏的复证）" >> $L
RT=/data/local/tmp/rt_shot63.bin
cd /data/local/tmp || echo "S3_cd_rc=$?" >> $L
./w976_arm $P $RT >> $L 2>&1
echo "S3_run_rc=$?" >> $L
echo "S3_rt_bytes=$(wc -c < $RT 2>&1)" >> $L
echo "S3_rt_md5=$(md5sum $RT 2>&1)" >> $L
echo "S3_cmp_pre_vs_rt=$(md5sum $P $RT 2>&1 | cut -d' ' -f1 | tr '\n' ' ')" >> $L
chmod 666 $P $RT $L 2>/dev/null
echo "END up=$(cat /proc/uptime)" >> $L
chmod 666 $L
