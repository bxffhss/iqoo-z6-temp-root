#!/system/bin/sh
# w967_mls_make.sh — #214 的**造尺子**那一步（root 腿，必须排在恢复执法**之前**）：
#   在 Termux 自己家里造两个兄弟目录，**类型完全相同**（`app_data_file:dir`）、**只差 MLS 类别**：
#     P = `app_data_file:s0`            （subject 的类别一定支配它）
#     Q = `app_data_file:s0:c93,c257`   （run-as com.termux 只有 `c512,c768` ⇒ 结构上不可能支配）
#   ⇒ 执法态下同一把尺子（同 uid、同域 `runas_app`、同 TE 规则集）量这两格：
#       P 通 & Q 被拒 ⇒ 挡路的**只能是 MLS 类别**（TE 不可能因类别不同而不同）；
#       P 也被拒 ⇒ MLS 解释不了 ⇒ 回到 **TE 缺规则**那一支。
#   ★为什么不用"找一家 debuggable 且类别更多的 app 当第二把 subject"：那依赖别人家的性质（可调试与否），
#     不是我能控的单变量；本尺子两格都在我们自己家里，DAC/属主/类型全同。
#   ★跑完由 w966 的尾巴（app 自己 uid）删掉这两个目录——执法后 root 删不动，所以**清理也排在执法之前不行**，
#     清理交给 Termux 自己的 uid 做（同 owner ⇒ DAC 允许）。
U() { cut -d' ' -f1 /proc/uptime 2>&1; }
O=/data/local/tmp/w967.out
D=/data/data/com.termux/files
P=$D/MLS_P_plain
Q=$D/MLS_Q_cats
{
  echo "G0 date=$(date) up=$(U) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>&1)"
  echo "G1 enf=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c '^kernelsu ' /proc/modules 2>&1) ★本腿要求 enf=0"
  mkdir $P 2>&1; echo "   mkdir P rc=$?"
  mkdir $Q 2>&1; echo "   mkdir Q rc=$?"
  chown -h 10667:10667 $P $Q 2>&1
  chmod 700 $P $Q 2>&1
  chcon u:object_r:app_data_file:s0 $P 2>&1; echo "   chcon P rc=$?"
  chcon u:object_r:app_data_file:s0:c93,c257 $Q 2>&1; echo "   chcon Q rc=$?"
  echo "G2 复证两格确实只差类别（属主/mode/类型必须相同）:"
  ls -ldZ $D 2>&1
  ls -ldZ $P $Q 2>&1
  echo "G3 各放一个文件（ls 目录时要 getdents；顺带量 file 类）:"
  echo p > $P/inner.txt 2>&1; echo "   写 P/inner rc=$?"
  echo q > $Q/inner.txt 2>&1; echo "   写 Q/inner rc=$?"
  chcon u:object_r:app_data_file:s0 $P/inner.txt 2>&1
  chcon u:object_r:app_data_file:s0:c93,c257 $Q/inner.txt 2>&1
  ls -lZ $P $Q 2>&1
  echo "G4 ★执法前正对照（Permissive 段两格都该通；这里红＝尺子本身坏，不是被测坏）:"
  run-as com.termux /system/bin/ls -l $P 2>&1 | head -2
  run-as com.termux /system/bin/ls -l $Q 2>&1 | head -2
  echo "   （上面两行若在 Permissive 段就报错 ⇒ 落点/DAC 坏了，#214 记「未测」，别读成 MLS 出局）"
  echo "GZ_END up=$(U) date=$(date)"
} > $O 2>&1
chmod 666 $O 2>&1
