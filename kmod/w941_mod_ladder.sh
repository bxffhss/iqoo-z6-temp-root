#!/system/bin/sh
# w941_mod_ladder.sh — 第 2 档（目标③"能不能装社区模块"）的一发阶梯，**只在 Permissive 段跑**。
# 三档逐个加，红在哪档就知道墙在哪档（排除法）：
#   档 1 脚本类   ＝ 模块的 post-fs-data.sh 由 runner 以 root 执行 ⇒ 判据＝selftest 件里 uid=0/enforce 那几行
#   档 2 文件替换类 ＝ system/etc/hosts 逐文件 bind ⇒ 判据＝marker 计数 0→1 ＋ md5 变了
#   档 3 卸干净    ＝ teardown 之后 md5 必须**回到装前那个值**（否则就是我们留下一处状态污染，例 178①那族）
# ★两把正对照自带：装前 md5/marker（应为 0）与卸后 md5（应回到装前值）；★不调 `su`（模块脚本里调 su 会命中
#   sucompat 改写＝§6.61 那颗雷），runner 已经是 uid 0。
# ★★落点全在 /data/local/tmp：这条腿翻执法后就写不出来了（§6.452 的 capability 一手）⇒ 必须排在恢复执法之前。
O=/data/local/tmp/w941.out
AP=/data/local/tmp/ksu_module_apply.sh
TD=/data/local/tmp/ksu_module_teardown.sh
MOD=/data/local/tmp/mod
U() { cut -d' ' -f1 /proc/uptime; }
{
  echo "S0 date=$(date) up=$(U) id=[$(id)]"
  echo "S1 enf=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -c '^kernelsu ' /proc/modules 2>&1) 夹具=$([ -d $MOD ] && echo 在 || echo 缺) runner=$([ -f $AP ] && echo 在 || echo 缺)"
  echo "== 装前（正对照：marker 必须=0）"
  md5sum /system/etc/hosts 2>&1
  head -1 /system/etc/hosts 2>&1
  echo "marker_before=$(grep -ac suw-module-marker /system/etc/hosts 2>/dev/null)"
  echo "bind_lines_before=$(grep -ac 'bind' /proc/self/mountinfo 2>/dev/null) total_mount=$(wc -l < /proc/self/mountinfo)"
} > $O 2>&1

echo "== 档1+档2：apply $MOD" >> $O 2>&1
sh $AP $MOD >> $O 2>&1
echo "APPLY_RC=$? up=$(U)" >> $O 2>&1

{
  echo "== apply 之后（判据）"
  md5sum /system/etc/hosts 2>&1
  echo "marker_after=$(grep -ac suw-module-marker /system/etc/hosts 2>/dev/null)"
  echo "bind_lines_after=$(grep -ac 'bind' /proc/self/mountinfo 2>/dev/null)"
  echo "-- runner 记的挂载表："
  cat /data/local/tmp/ksu_mod_mounts.txt 2>&1 | head -6
  echo "-- 模块脚本自己写的 selftest 件（档 1 的判据）："
  cat /data/local/tmp/ksu_mod_selftest.txt 2>&1 | head -10
} >> $O 2>&1

echo "== 档3：teardown" >> $O 2>&1
sh $TD $MOD >> $O 2>&1
echo "TD_RC=$? up=$(U)" >> $O 2>&1

{
  echo "== 卸后（必须回到装前状态）"
  md5sum /system/etc/hosts 2>&1
  echo "marker_left=$(grep -ac suw-module-marker /system/etc/hosts 2>/dev/null)"
  echo "bind_lines_left=$(grep -ac 'bind' /proc/self/mountinfo 2>/dev/null)"
  echo "-- 交付链没被我碰坏的证人：su 层还在、改道落点还在"
  ls -l /product/bin/su /data/local/tmp/kd 2>&1 | cut -d' ' -f1,3,5
  echo "SZ_END date=$(date) up=$(U)"
} >> $O 2>&1
chmod 666 $O 2>&1
