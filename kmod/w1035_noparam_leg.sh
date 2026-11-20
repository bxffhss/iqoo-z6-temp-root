#!/system/bin/sh
# w1035_noparam_leg.sh —— 第 77 发：2×2 的第四格(真 init 体 × **不传任何参数**)。
#
# ★这一格为什么必须打：§6.489 的自审——第 76 发(同料**空 init**、无参)判正，但它和第 72/73 发(真 init 体、
#   `rt_steps=5`)之间差了**两个变量**：①init 体 ②命令行有没有传参。⇒ "装载期无罪"只对"无参装载"成立，
#   **参数那条路还没被排除**；而它恰好是"init 一个字都没印却炸机"的最省事解释(参数在 load_module() 的
#   parse_args() 里处理，位置**早于** do_one_initcall)。
#   ⇒ 本腿把第四格补上：**同一个 v4 件、init 体一字不改、命令行一个参数都不给**。
# 四格表(读的时候别并档)：
#   空 init × 无参 ＝ 第 76 发 ⇒ 活
#   真 init × 传 rt_steps=5 ＝ 第 72/73 发 ⇒ 当场硬复位
#   真 init × **无参** ＝ **这一发**
#   (空 init × 传参＝没做，它只在上一格翻面时才需要)
#
# ★这一格真正量的东西：`rt_steps` 默认 0 ⇒ init 只走 pr_info → 4 次符号解析(kprobe 取 kallsyms_lookup_name)
#   → avtab_cache_init() → rt_stage=99 收工。**不读活策略、不解析、不重写、更不装载**(rt_load_rc 恒 -1)。
# 结构上不写运行期策略：`do_load` 需要 0x4C4F4144 这把钥匙，本腿永远不传；装前装后各导一次活策略比 md5。
L=/data/local/tmp/w1035_noparam.out
K=/data/local/tmp/w986_polround_v4_cfi.ko
MD5_EXPECT=f0e8ee245b231d827665b7aed9f30db7
MOD=w985_probe
PRE=/data/local/tmp/w1035_pol.pre
POST=/data/local/tmp/w1035_pol.post
: > $L
echo "BEGIN up=$(cat /proc/uptime) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)" >> $L
echo "ARM=无参(命令行只给件路径) ko=$K expect=$MD5_EXPECT" >> $L
sync

# --- 0) 卫生腿并到正题里(第 63 发的规矩：卫生格不许单独占一次派单) ---
for D in /data/data/com.termux/files/MLS_Q_cats /data/data/com.termux/files/W99_P9 /data/data/com.termux/files/W99_Q9 /data/data/com.termux/files/W18_P /data/data/com.termux/files/W18_Q /data/local/tmp/w1018_sP /data/local/tmp/w1018_sQ; do
  if [ -e "$D" ]; then
    rm -rf "$D" 2>/dev/null
    echo "CLEANUP $D rm_rc=$? still_there=$([ -e "$D" ] && echo YES || echo NO)" >> $L
  else
    echo "CLEANUP $D 不在(已净)" >> $L
  fi
done
sync

# --- 1) 件的对表：md5 不符就不 insmod(防"旧件静默换形状") ---
if [ ! -f "$K" ]; then
  echo "[x] $K 不在 ⇒ 停" >> $L
  echo "NP_VERDICT=未测(件不在)" >> $L
  chmod 666 $L; exit 1
fi
m=$(md5sum $K | cut -d' ' -f1)
echo "ko_bytes=$(wc -c < $K) ko_md5=$m" >> $L
if [ "$m" != "$MD5_EXPECT" ]; then
  echo "[x] md5 不符(期望 $MD5_EXPECT) ⇒ 不 insmod" >> $L
  echo "NP_VERDICT=未测(md5 对不上)" >> $L
  chmod 666 $L; exit 1
fi

# --- 2) 装之前的活策略(这一行也是"腿走到了第 2 步"的一手证人) ---
/system/bin/cat /sys/fs/selinux/policy > $PRE
echo "PRE_rc=$? pre_bytes=$(wc -c < $PRE) pre_md5=$(md5sum $PRE | cut -d' ' -f1)" >> $L
sync

# --- 3) ★insmod：**一个参数都不给**；这一行本身先落证件再 sync(第 72 发的教训：致死步之前不许没留话) ---
echo "ARGV=insmod $K" >> $L
sync
insmod $K
RC=$?
echo "insmod_rc=$RC" >> $L
sync
INMOD=$(grep -c "^$MOD " /proc/modules)
if [ "$INMOD" = "1" ]; then
  echo "MODULES_LINE=$(grep "^$MOD " /proc/modules)" >> $L
else
  echo "[!!] /proc/modules 里没有 $MOD(计数=$INMOD) ⇒ 下面读不到参数是必然，别当通过" >> $L
fi

# --- 4) 参数面立刻抄件(rmmod 会连参数一起摘掉)；★rt_steps 本身＝"这一发确实是无参臂"的证人 ---
for f in rt_steps do_load rt_stage rt_sym_rc rt_slab_rc rt_rd_rc rt_prs_rc rt_wr_rc rt_load_rc \
         rt_pre_len rt_wr_len rt_same rt_ver rt_mls rt_nel rt_sum_pre rt_sum_wr rt_proc; do
  echo "PARAM $f=$(cat /sys/module/$MOD/parameters/$f 2>&1)" >> $L
done
sync

# --- 5) 装载期那几行 printk(dmesg 通道会吞，所以只当辅助证人，不当判据) ---
dg=$(dmesg 2>/dev/null | grep -ac 'w986')
echo "DMESG_w986_lines=$dg" >> $L
dmesg 2>/dev/null | grep -a 'w986' | tail -10 >> $L
sync

# --- 6a) 读数：一次把判据要用的五个量取进变量(判据块只碰变量，selftest 才好注入) ---
ST=$(cat /sys/module/$MOD/parameters/rt_stage 2>/dev/null)
STEPSR=$(cat /sys/module/$MOD/parameters/rt_steps 2>/dev/null)
SYM=$(cat /sys/module/$MOD/parameters/rt_sym_rc 2>/dev/null)
SLAB=$(cat /sys/module/$MOD/parameters/rt_slab_rc 2>/dev/null)
LR=$(cat /sys/module/$MOD/parameters/rt_load_rc 2>/dev/null)

# --- 6b) 判据(五支，每支都说清"这一格量的是什么") ---
if [ "$INMOD" != "1" ]; then
  if [ "$RC" = "0" ]; then
    echo "NP_VERDICT=未测(insmod 报 0 但 /proc/modules 里没有它 ⇒ 读数自相矛盾，别当结论)" >> $L
  else
    echo "NP_VERDICT=判负(无参也被拒 rc=$RC ⇒ 看装载回执原因；机器若活着，这一格还没解释第 72/73 发)" >> $L
  fi
elif [ "$STEPSR" != "0" ]; then
  echo "NP_VERDICT=未测(rt_steps 读回=$STEPSR ⇒ 这不是无参臂，本发的结论不能套到 2×2 上)" >> $L
elif [ "$ST" = "99" ]; then
  echo "NP_VERDICT=判正(真 init 体 × 无参 ⇒ 活到 steps=0 的出口；sym_rc=$SYM slab_rc=$SLAB。⇒ 杀手需要「传参」这一维，#216-B 不许再走模块参数信道)" >> $L
elif [ "$ST" = "-1" ]; then
  echo "NP_VERDICT=未测(在册却 stage=-1 ⇒ init 体一步都没跑，与 insmod_rc=$RC 矛盾，先查仪器)" >> $L
else
  echo "NP_VERDICT=停在第 $ST 步(★未定位：sym_rc=$SYM slab_rc=$SLAB load_rc=$LR ⇒ 对照源码看那一步是什么)" >> $L
fi
sync

# --- 7) 拆干净 + ★活策略复证(装前装后两份 md5 相同＝我们没碰运行期策略) ---
rmmod $MOD
echo "rmmod_rc=$? mod_left=$(grep -c "^$MOD " /proc/modules)" >> $L
/system/bin/cat /sys/fs/selinux/policy > $POST
echo "POST_rc=$? post_bytes=$(wc -c < $POST) post_md5=$(md5sum $POST | cut -d' ' -f1)" >> $L
sync
PM=$(md5sum $PRE | cut -d' ' -f1)
QM=$(md5sum $POST | cut -d' ' -f1)
if [ "$PM" = "$QM" ]; then
  echo "POLICY_UNCHANGED=1(判据：运行期策略装前装后逐字节相同) rt_load_rc 应仍=-1" >> $L
else
  echo "[x] POLICY_UNCHANGED=0 ⇒ 装前装后不一样了，这是**大事**，立刻记进 DELIVERY 未通过项" >> $L
fi
echo "END up=$(cat /proc/uptime)" >> $L
chmod 666 $PRE $POST $L 2>/dev/null
sync
