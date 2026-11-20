#!/system/bin/sh
# w1038_steprzero_leg.sh —— 第 78 发：**传参但值＝默认**(`rt_steps=0`)⇒ 与第 77 发只差"命令行上有没有那一段"。
#
# ★第 77 发已判正(一手：`insmod_rc=0`→`rt_steps=0`→`rt_stage=99`→dmesg 三行齐→`rmmod` 干净→装前装后活策略
#   md5 相同)，于是 2×2 只剩两个候选，且**两者都能解释"init 一字未印却炸机"**：
#     (甲) 传参本身＝`parse_args()`(位置早于 `do_one_initcall`，所以 init 没印也说得通)
#     (乙) `rt_steps≥1` 才跑的那段 SS 代码(`security_read_policy`→`policydb_read`→`policydb_write`)
#   ⇒ **本腿只做一件事**：init 轨迹与第 77 发**完全同一格**(steps=0 ⇒ 同样只走到 `rt_stage=99` 就收)，
#     唯一差别＝命令行显式给了 `rt_steps=0`。这一格翻面就归因，不翻面就排除。
#   读法：判正(活到 99) ⇒ **(甲)出局**，凶手在(乙) ⇒ 下一格 `rt_steps=1` 只多"读活策略"这一步来二分；
#         当场复位(证件断在 `ARGV=` 之后) ⇒ **(甲)坐实**，#216-B 从此不许走模块参数信道(改编译期常量)。
# 表(别并档)：空 init×无参＝76 活｜真 init×无参＝77 活｜真 init×`rt_steps=5`＝72/73 死｜**真 init×`rt_steps=0`＝本发**
#
# ★两臂证人：`ARGV=` 那行必须带 `rt_steps=0`(证明参数真给了)，`PARAM rt_steps=0`(证明 parse_args 真写进去了)。
# 结构上不写运行期策略：`do_load` 需要 0x4C4F4144 这把钥匙，本腿永远不传；装前装后各导一次活策略比 md5。
L=/data/local/tmp/w1038_steprzero.out
K=/data/local/tmp/w986_polround_v4_cfi.ko
MD5_EXPECT=f0e8ee245b231d827665b7aed9f30db7
MOD=w985_probe
PRE=/data/local/tmp/w1035_pol.pre
POST=/data/local/tmp/w1035_pol.post
: > $L
echo "BEGIN up=$(cat /proc/uptime) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)" >> $L
echo "ARM=传参但值＝默认(rt_steps=0，init 轨迹与第 77 发同一格) ko=$K expect=$MD5_EXPECT" >> $L
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
echo "ARGV=insmod $K rt_steps=0" >> $L
sync
insmod $K rt_steps=0
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
    echo "NP_VERDICT=判负(带 rt_steps=0 也被拒 rc=$RC ⇒ 看装载回执原因；机器若活着，这一格还没解释第 72/73 发)" >> $L
  fi
elif [ "$STEPSR" != "0" ]; then
  echo "NP_VERDICT=未测(命令行给了 rt_steps=0 却读回 $STEPSR ⇒ parse_args 没写成，本发对照不成立，先查参数名)" >> $L
elif [ "$ST" = "99" ]; then
  echo "NP_VERDICT=判正(传了参、init 轨迹与第 77 发同一格 ⇒ (甲)传参本身出局，凶手在 rt_steps>=1 那段 SS 代码 ⇒ 下一格 rt_steps=1 二分；sym_rc=$SYM slab_rc=$SLAB)" >> $L
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
