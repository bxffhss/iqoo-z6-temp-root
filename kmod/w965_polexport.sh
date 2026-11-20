#!/system/bin/sh
# w965_polexport.sh — 翻执法**之前**必须做的一件事：把内核正在用的策略导出来（#216 的"以 live 件为底"要用它当基准）。
#   ★为什么排在执法之前：执法态下 shell/root 都读不动 `/sys/fs/selinux/policy`（§6.452：读出来 `SIZE=0`＝没读到，不等于空策略）。
#   ★跑法（root 腿，免打字）：run-as com.termux 把本件送进 app 家，再 `env /system/bin/su < 脚本`；
#     产物落 `/data/local/tmp/`（root 建不了文件 ⇒ 由本腿以 root 身份建，**趁还没翻执法**，§6.441 那条能力闸）。
#   判据：件字节数必须是 1,356,948 量级（与 odm 盘件同尺寸）；`SIZE=0`/空 ⇒ 写"未测"，不当"策略是空的"。
U() { cut -d' ' -f1 /proc/uptime 2>&1; }
O=/data/local/tmp/w965.out
P=/data/local/tmp/pol.live_1027
{
  echo "E0 date=$(date) up=$(U) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>&1)"
  echo "E1 enf=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c '^kernelsu ' /proc/modules 2>&1)"
  echo "E2 导出 live 策略:"
  cat /sys/fs/selinux/policy > $P 2>&1
  rc=$?
  echo "   cat rc=$rc bytes=$(wc -c < $P 2>&1) md5=$(md5sum $P 2>&1 | cut -d' ' -f1)"
  echo "E3 对照盘上厂商件（同一内核的两份来源）:"
  md5sum /odm/etc/selinux/precompiled_sepolicy 2>&1
  wc -c /odm/etc/selinux/precompiled_sepolicy 2>&1
  echo "E4 制式魔数（前 4 字节，小端读法见 §6.453：0xf97cff8c=module 制式）:"
  od -An -tx1 -N4 $P 2>&1
  od -An -tx1 -N4 /odm/etc/selinux/precompiled_sepolicy 2>&1
  echo "E5 顺带把 #214 的前置条件钉一下（vtools 是不是 debuggable＝能不能 run-as 进去当超集类别的 subject）:"
  run-as com.omarea.vtools id 2>&1 | head -1
  echo "   该项 rc=$?  ★rc≠0 ⇒ #214 这一格走「未测」，不许读成「MLS 出局」"
  echo "E6 uid/类别对照（两把 subject 各是什么）:"
  pm list packages -U 2>/dev/null | grep -E "omarea.vtools|com.termux$" | tr -d '\r'
  cat /proc/self/attr/current 2>&1
  chmod 666 $O $P 2>&1
  echo "EZ_END up=$(U) date=$(date)"
} > $O 2>&1
chmod 666 $O 2>&1
