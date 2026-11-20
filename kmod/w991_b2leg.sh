#!/system/bin/sh
# w991_b2leg.sh —— #216-B2 的**设备侧**腿（root 跑；产物给人用**非 root** 读参数那一步在前，见 §6.464）。
# ★本脚本自己**不碰** /sys/fs/selinux/*，也不带 do_load ⇒ 结构上不写策略。
# 判据：ko_md5 对得上才 insmod；insmod_rc、/proc/modules 那行、rt_* 参数全表、dmesg 里 W986 的行。
# ★跑完 rmmod 之前先把参数抄进 $L（rmmod 会连参数面一起摘掉）。
L=/data/local/tmp/w991_b2.out
K=/data/local/tmp/w986_polround.ko
MD5_EXPECT=f116eb390b22e8d85b924adc0ae54f8f   # 10-27 09:4x 硬化版(唯一 slab 名＋去 panic 旗标＋/proc 导出)
MOD=w985_probe
: > $L
echo "BEGIN up=$(cat /proc/uptime)" >> $L
echo "enforce=$(cat /sys/fs/selinux/enforce 2>&1)" >> $L
if [ ! -f $K ]; then
  echo "[x] $K 不在 ⇒ 停" >> $L
  chmod 666 $L
  exit 1
fi
echo "ko_bytes=$(wc -c < $K)" >> $L
m=$(md5sum $K | cut -d' ' -f1)
echo "ko_md5=$m" >> $L
echo "expect=$MD5_EXPECT" >> $L
if [ "$m" != "$MD5_EXPECT" ]; then
  echo "[x] md5 不符 ⇒ 不 insmod（旧件会静默换形状，§6.155 那一族）" >> $L
  chmod 666 $L
  exit 1
fi
insmod $K
echo "insmod_rc=$?" >> $L
if grep -q "^$MOD " /proc/modules; then
  echo "MODULES_LINE=$(grep "^$MOD " /proc/modules)" >> $L
else
  echo "[!!] /proc/modules 里没有 $MOD ⇒ 下面参数读不到是必然，别当『判据过了』" >> $L
fi
for f in /sys/module/$MOD/parameters/rt_stage /sys/module/$MOD/parameters/rt_sym_rc \
         /sys/module/$MOD/parameters/rt_rd_rc /sys/module/$MOD/parameters/rt_prs_rc \
         /sys/module/$MOD/parameters/rt_wr_rc /sys/module/$MOD/parameters/rt_pre_len \
         /sys/module/$MOD/parameters/rt_wr_len /sys/module/$MOD/parameters/rt_same \
         /sys/module/$MOD/parameters/rt_ver /sys/module/$MOD/parameters/rt_mls \
         /sys/module/$MOD/parameters/rt_nel /sys/module/$MOD/parameters/rt_sum_pre \
         /sys/module/$MOD/parameters/rt_sum_wr /sys/module/$MOD/parameters/rt_slab_rc /sys/module/$MOD/parameters/rt_proc /sys/module/$MOD/parameters/rt_load_rc \
         /sys/module/$MOD/parameters/do_load; do
  echo "PARAM ${f##*/}=$(cat $f 2>&1)" >> $L
done
# ★这里**不取** $?：管道末端是 tail，$? 是 tail 的（本仓第三次踩，例 186③）。dmesg 有没有抓到行，
#   由下面那行"命中计数"自己说话；取数写法＝先整体捕获再取 rc。
# ★把模块重序列化出来的那份镜像取走(§6.456 的教训：字节不等≠语义不等，
#   没有这份产物，红就只是红，量不出"红在哪")。0400＝只有这条 root 腿读得到，取完 chmod 666 给 adb pull。
if [ -r /proc/w986_wr ]; then
  W=/data/local/tmp/w986_wr.bin
  cat /proc/w986_wr > $W
  echo "WR_dump_rc=$? bytes=$(wc -c < $W 2>&1) md5=$(md5sum $W 2>&1)" >> $L
  chmod 666 $W 2>/dev/null
else
  echo "[!!] /proc/w986_wr 不在或不可读(rt_proc 会说原因) ⇒ 这格记未取到，不许当过了" >> $L
fi
dg=$(dmesg 2>/dev/null | grep -ac 'w986' 2>/dev/null)
echo "DMESG_w986_lines=$dg" >> $L
dmesg 2>/dev/null | grep -a 'w986' | tail -25 >> $L
rmmod $MOD
echo "rmmod_rc=$?" >> $L
echo "END up=$(cat /proc/uptime)" >> $L
chmod 666 $L
