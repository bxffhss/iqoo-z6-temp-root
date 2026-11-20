#!/system/bin/sh
# w995_merged_leg.sh —— 第 64 发的**唯一一支** root 腿（窗预算≈insmod+600–700 秒，派单一次吃 30–60 秒，
#   所以按 §6.466 的教训合并成一支，**B2 排最前**）。
# ★结构上不写策略：只 insmod 一个自带 SS 源码的只读往返模块，`do_load` 不给钥匙 ⇒ 不可能调 load；
#   并且**腿开头导一次活策略、结尾再导一次**，两份 md5 相同＝"这台机的运行期策略一个字都没变"的一手证人。
L=/data/local/tmp/w995_merged.out
K=/data/local/tmp/w986_polround.ko
MD5_EXPECT=f116eb390b22e8d85b924adc0ae54f8f
MOD=w985_probe
PRE=/data/local/tmp/pol.pre_shot64
POST=/data/local/tmp/pol.post_shot64
WR=/data/local/tmp/w986_wr.bin
: > $L
echo "BEGIN up=$(cat /proc/uptime) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)" >> $L

# --- 0) 件的对表（md5 不符就不 insmod；这是防"旧件静默换形状"§6.155）---
if [ ! -f $K ]; then
  echo "[x] $K 不在 ⇒ 停" >> $L
  chmod 666 $L; exit 1
fi
m=$(md5sum $K | cut -d' ' -f1)
echo "ko_bytes=$(wc -c < $K) ko_md5=$m expect=$MD5_EXPECT" >> $L
if [ "$m" != "$MD5_EXPECT" ]; then
  echo "[x] md5 不符 ⇒ 不 insmod" >> $L
  chmod 666 $L; exit 1
fi

# --- 1) 装之前的活策略（对照用）---
/system/bin/cat /sys/fs/selinux/policy > $PRE
echo "PRE_rc=$? pre_bytes=$(wc -c < $PRE) pre_md5=$(md5sum $PRE | cut -d' ' -f1)" >> $L
sync   # ★落盘一次：硬复位会吞掉没 sync 的证据(§6.468 第 65 发

# --- 2) ★B2：insmod 只读往返探针，参数面立刻抄进本件（rmmod 会连参数一起摘掉）---
insmod $K
echo "insmod_rc=$?" >> $L
if grep -q "^$MOD " /proc/modules; then
  echo "MODULES_LINE=$(grep "^$MOD " /proc/modules)" >> $L
else
  echo "[!!] /proc/modules 里没有 $MOD ⇒ 下面读不到参数是必然，别当通过" >> $L
fi
for f in /sys/module/$MOD/parameters/rt_stage /sys/module/$MOD/parameters/rt_sym_rc \
         /sys/module/$MOD/parameters/rt_slab_rc /sys/module/$MOD/parameters/rt_rd_rc \
         /sys/module/$MOD/parameters/rt_prs_rc /sys/module/$MOD/parameters/rt_wr_rc \
         /sys/module/$MOD/parameters/rt_pre_len /sys/module/$MOD/parameters/rt_wr_len \
         /sys/module/$MOD/parameters/rt_same /sys/module/$MOD/parameters/rt_ver \
         /sys/module/$MOD/parameters/rt_mls /sys/module/$MOD/parameters/rt_nel \
         /sys/module/$MOD/parameters/rt_sum_pre /sys/module/$MOD/parameters/rt_sum_wr \
         /sys/module/$MOD/parameters/rt_proc /sys/module/$MOD/parameters/rt_load_rc \
         /sys/module/$MOD/parameters/do_load; do
  echo "PARAM ${f##*/}=$(cat $f 2>&1)" >> $L
done
# 模块重序列化那份取走（rt_same=0 时靠它离线跑 w953b，而不是只拿一个"红"）
if [ -r /proc/w986_wr ]; then
  cat /proc/w986_wr > $WR
  echo "WR_rc=$? wr_bytes=$(wc -c < $WR) wr_md5=$(md5sum $WR | cut -d' ' -f1)" >> $L
  chmod 666 $WR 2>/dev/null
else
  echo "[!!] /proc/w986_wr 不可读（看上面 rt_proc/insmod_rc 说原因）⇒ 这格记未取到" >> $L
fi
dg=$(dmesg 2>/dev/null | grep -ac 'w986')
sync   # ★落盘一次：硬复位会吞掉没 sync 的证据(§6.468 第 65 发
echo "DMESG_w986_lines=$dg" >> $L
dmesg 2>/dev/null | grep -a 'w986' | tail -30 >> $L

# --- 3) 拆干净 + ★活策略复证（装前后两份 md5 必须相同＝我们没碰运行期策略）---
rmmod $MOD
echo "rmmod_rc=$? mod_left=$(grep -c "^$MOD " /proc/modules)" >> $L
/system/bin/cat /sys/fs/selinux/policy > $POST
echo "POST_rc=$? post_bytes=$(wc -c < $POST) post_md5=$(md5sum $POST | cut -d' ' -f1)" >> $L
sync   # ★落盘一次：硬复位会吞掉没 sync 的证据(§6.468 第 65 发
if [ "$(md5sum $PRE | cut -d' ' -f1)" = "$(md5sum $POST | cut -d' ' -f1)" ]; then
  echo "POLICY_UNCHANGED=1（判据：运行期策略装前装后逐字节相同）" >> $L
else
  echo "[x] POLICY_UNCHANGED=0 ⇒ 装前装后不一样了，这是**大事**，立刻记进 DELIVERY 未通过项" >> $L
fi
chmod 666 $PRE $POST $L 2>/dev/null
echo "END up=$(cat /proc/uptime)" >> $L
chmod 666 $L
