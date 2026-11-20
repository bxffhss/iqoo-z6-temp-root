#!/system/bin/sh
# w1042_step1_leg.sh —— 第 79 发：`rt_steps=1` ⇒ 在"第 77/78 发那一格"之上**只多加一步**：调 `security_read_policy`。
#
# ★现在的归因面(§6.492)：2×2 已把(甲)摘干净——空 init×无参＝76 活｜真 init×无参＝77 活｜真 init×`rt_steps=0`(传了参)＝78 活
#   ⇒ **传参这条机器学无罪**，凶手下唯一 surviving 候选是 (乙)`rt_steps≥1` 才执行的代码。本腿把(乙)再切一刀：
#   `steps=1` 只跑 stage 2(`security_read_policy(state,&img,&len)` → fnv64 → vfree)，然后走 `rt_steps<3` 的早退出口。
#   读法(四支)：**复位**(证件断在 `ARGV=` 之后) ⇒ 凶手＝**在模块里调内核那个序列化函数这件事本身**
#     ⇒ #216-B 换形状：不再让内核给我们导出，改成**用户态把 `/sys/fs/selinux/policy` 的字节流喂进模块**；
#     **判正且 `rd_rc=0`/`pre_len=1356948`** ⇒ 这一步能走通(还顺手量到"内核导出的字节数=装前那份")，凶手在
#     **我们那份 reader/writer**(stage 3/4) ⇒ 下一格 `rt_steps=2`；**判正但 `rd_rc≠0`** ⇒ 调用失败但不是崩，
#     按 rc 归因(-EPERM/-EINVAL/-EOPNOTSUPP…)；**在册却 `rt_rd_rc=-1`** ⇒ 未测(没走到 stage 2，先查仪器)。
# ★证人三行：`ARGV=` 带 `rt_steps=1` ＋ `PARAM rt_steps=1`(parse_args 真写进去了) ＋ `WANT_STEPS=1`(自测现读这条臂)。
# 结构上不写运行期策略：`do_load` 需要 0x4C4F4144 这把钥匙，本腿永远不传；装前装后各导一次活策略比 md5。
L=/data/local/tmp/w1042_step1.out
K=/data/local/tmp/w986_polround_v4_cfi.ko
MD5_EXPECT=f0e8ee245b231d827665b7aed9f30db7
MOD=w985_probe
WANT_STEPS=1
PRE=/data/local/tmp/w1042_pol.pre
POST=/data/local/tmp/w1042_pol.post
: > $L
echo "BEGIN up=$(cat /proc/uptime) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)" >> $L
echo "ARM=传 rt_steps=1(比第 78 发只多 stage 2：security_read_policy) ko=$K expect=$MD5_EXPECT WANT_STEPS=$WANT_STEPS" >> $L
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
echo "ARGV=insmod $K rt_steps=1" >> $L
sync
insmod $K rt_steps=1
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
RD=$(cat /sys/module/$MOD/parameters/rt_rd_rc 2>/dev/null)
PLEN=$(cat /sys/module/$MOD/parameters/rt_pre_len 2>/dev/null)
PSUM=$(cat /sys/module/$MOD/parameters/rt_sum_pre 2>/dev/null)

# --- 6b) 判据(六支，每支都说清"这一格量的是什么"；臂证人用腿顶的 WANT_STEPS，自测也现读它) ---
if [ "$INMOD" != "1" ]; then
  if [ "$RC" = "0" ]; then
    echo "NP_VERDICT=未测(insmod 报 0 但 /proc/modules 里没有它 ⇒ 读数自相矛盾，别当结论)" >> $L
  else
    echo "NP_VERDICT=判负(带 rt_steps=$WANT_STEPS 也被拒 rc=$RC ⇒ 看装载回执原因；机器若活着，这一格还没解释第 72/73 发)" >> $L
  fi
elif [ "$STEPSR" != "$WANT_STEPS" ]; then
  echo "NP_VERDICT=未测(命令行给了 rt_steps=$WANT_STEPS 却读回 $STEPSR ⇒ parse_args 没写成，本发对照不成立，先查参数名)" >> $L
elif [ "$ST" = "99" ] && [ "$RD" = "0" ]; then
  echo "NP_VERDICT=判正(内核自己把活策略序列化出来了：rd_rc=0 pre_len=$PLEN sum_pre=$PSUM ⇒ stage 2 走得通，凶手收窄到**我们那份 reader/writer**(stage 3/4) ⇒ 下一格把 steps 加一)" >> $L
elif [ "$ST" = "99" ]; then
  echo "NP_VERDICT=判负(活到了出口但那次调用失败：rd_rc=$RD pre_len=$PLEN ⇒ 按 rc 归因；机器活着＝这不是崩，是返回错误)" >> $L
elif [ "$ST" = "-1" ]; then
  echo "NP_VERDICT=未测(在册却 stage=-1 ⇒ init 体一步都没跑，与 insmod_rc=$RC 矛盾，先查仪器)" >> $L
else
  echo "NP_VERDICT=停在第 $ST 步(★未定位：sym_rc=$SYM slab_rc=$SLAB rd_rc=$RD load_rc=$LR ⇒ 对照源码看那一步是什么)" >> $L
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
