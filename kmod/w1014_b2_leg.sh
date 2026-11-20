#!/system/bin/sh
# w1014_b2_leg.sh —— #216-B2 的**上一支**腿（取代 kmod/w995_merged_leg.sh）。
#
# ★为什么必须有第二份：w995 那支写的是 `insmod $K` 不带任何参数，而这个模块的 `rt_steps` **默认＝0**
#   (保守默认＝裸 insmod 只做符号解析＋建 slab，然后 rt_stage=99 收工)。
#   ⇒ 那一支**结构上跑不到往返**：rt_same 永远是 -1，rt_stage 永远 99，判据没有牙。
#   第 66 发的复位就发生在这种"只解析了符号"的装载之后 ⇒ "我的 SS 代码把机器打崩了"那个读法要收窄。
# ★本腿把 STEPS 显式传给 insmod，并且**把 rt_steps 本身抄回证件**＝"这个件真跑了哪几步"的一手证人。
# ★结构上不写运行期策略：`do_load` 永远不传(需要 0x4C4F4144 这把钥匙)，装前装后各导一次活策略比 md5。
#
# 用法：只改下面 STEPS 那一个数，再 push 上机随 LEG1 派。
#   STEPS=0 只解析符号＋建 slab   1 加 security_read_policy   2 加我们那份 policydb_read
#         3 加我们那份 policydb_write(★rt_same 就在这一步出)  4 加复读  5 加 /proc/w986_wr(取产物做语义比对)
L=/data/local/tmp/w1014_b2.out
K=/data/local/tmp/w986_polround_v4_cfi.ko
MD5_EXPECT=f0e8ee245b231d827665b7aed9f30db7
STEPS=5
MOD=w985_probe
PRE=/data/local/tmp/w1014_pol.pre
POST=/data/local/tmp/w1014_pol.post
WR=/data/local/tmp/w986_wr_v4.bin
: > $L
echo "BEGIN up=$(cat /proc/uptime) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)" >> $L
echo "STEPS=$STEPS ko=$K expect=$MD5_EXPECT" >> $L
sync

# --- 0a) ★两行免费读数(§6.480：第 71 发 A 组那格 can't open…Permission denied 的两条候选就靠这两行分开) ---
#   趁尾巴还在、还在 Permissive 段做：
#     CapEff 决定这把 root 壳有没有 CAP_DAC_OVERRIDE —— /data/data/com.termux 是 0700 且属主不是 root，
#       没这条 cap 就**连门都进不去**，那 EACCES 与 SELinux／厂商闸都无关(＝§6.447 归给 capability 那一支)；
#     祖先标签决定"某一格缺 dir:search"这条候选还活不活着(拿现读标签去对活策略，离线就能判)。
grep -a '^CapEff' /proc/self/status >> $L 2>&1
for A in /data /data/data /data/data/com.termux /data/data/com.termux/files; do
  echo "ANC $A=$(ls -dZ $A 2>&1 | tr -s ' ')" >> $L
done
sync

# --- 0) 卫生腿并到正题里(第 63 发的教训：卫生格不许单独占一次派单) ---
#     §6.460 留的 MLS 尾巴 + 第 67 发 #219 留下的两把尺子，MLS 连属主 unlink 都挡，只有 root 腿删得掉。
for D in /data/data/com.termux/files/MLS_Q_cats /data/data/com.termux/files/W99_P9 /data/data/com.termux/files/W99_Q9 /data/data/com.termux/files/W18_P /data/data/com.termux/files/W18_Q /data/local/tmp/w1018_sP /data/local/tmp/w1018_sQ; do
  if [ -e "$D" ]; then
    rm -rf "$D" 2>/dev/null
    echo "CLEANUP $D rm_rc=$? still_there=$([ -e "$D" ] && echo YES || echo NO)" >> $L
  else
    echo "CLEANUP $D 不在(已净)" >> $L
  fi
done
sync

# --- 1) 件的对表：md5 不符就不 insmod(防"旧件静默换形状"§6.155) ---
if [ ! -f "$K" ]; then
  echo "[x] $K 不在 ⇒ 停" >> $L
  echo "B2_VERDICT=未测(件不在)" >> $L
  chmod 666 $L; exit 1
fi
m=$(md5sum $K | cut -d' ' -f1)
echo "ko_bytes=$(wc -c < $K) ko_md5=$m" >> $L
if [ "$m" != "$MD5_EXPECT" ]; then
  echo "[x] md5 不符(期望 $MD5_EXPECT) ⇒ 不 insmod" >> $L
  echo "B2_VERDICT=未测(md5 对不上)" >> $L
  chmod 666 $L; exit 1
fi

# --- 2) 装之前的活策略(对照用) ---
/system/bin/cat /sys/fs/selinux/policy > $PRE
echo "PRE_rc=$? pre_bytes=$(wc -c < $PRE) pre_md5=$(md5sum $PRE | cut -d' ' -f1)" >> $L
sync

# --- 3) ★insmod 并把 STEPS 传进去；这一行本身抄进证件 ---
# ★★★第 72 发一手教训：`ARGV=` 这行写下去之后**没有 sync**，机器在 insmod 当场硬复位(PS_HOLD)
#   ⇒ 页缓存里那行连同 `insmod_rc=` 全丢了，证件最后只剩上一段 sync 过的 `PRE_rc=0`。
#   结果"腿没走到 insmod"和"走到了但死在里面"这两种读法**分不开**＝判据没有牙。
#   ⇒ 规矩：**任何可能致死的一步之前**，把"我即将做什么"写进证件并 sync；事后那行也要紧跟 sync。
echo "ARGV=insmod $K rt_steps=$STEPS" >> $L
sync
insmod $K rt_steps=$STEPS
echo "insmod_rc=$?" >> $L
sync
if grep -q "^$MOD " /proc/modules; then
  echo "MODULES_LINE=$(grep "^$MOD " /proc/modules)" >> $L
else
  echo "[!!] /proc/modules 里没有 $MOD ⇒ 下面读不到参数是必然，别当通过" >> $L
fi

# --- 4) 参数面立刻抄件(rmmod 会连参数一起摘掉)；★含 rt_steps 本身 ---
for f in rt_steps rt_stage rt_sym_rc rt_slab_rc rt_rd_rc rt_prs_rc rt_wr_rc rt_load_rc \
         rt_pre_len rt_wr_len rt_same rt_ver rt_mls rt_nel rt_sum_pre rt_sum_wr rt_proc do_load; do
  echo "PARAM $f=$(cat /sys/module/$MOD/parameters/$f 2>&1)" >> $L
done
sync

# --- 5) 模块重序列化那份取走(rt_same=0 时靠它离线跑 w953b，而不是只拿一个"红") ---
if [ -r /proc/w986_wr ]; then
  cat /proc/w986_wr > $WR
  echo "WR_rc=$? wr_bytes=$(wc -c < $WR) wr_md5=$(md5sum $WR | cut -d' ' -f1)" >> $L
  chmod 666 $WR 2>/dev/null
else
  echo "[!!] /proc/w986_wr 不可读(看 rt_proc/rt_stage 说原因)⇒ 这格记未取到" >> $L
fi
dg=$(dmesg 2>/dev/null | grep -ac 'w986')
echo "DMESG_w986_lines=$dg" >> $L
dmesg 2>/dev/null | grep -a 'w986' | tail -25 >> $L
sync

# --- 6) ★判据(带牙)：只有"我们那份 writer 真的跑成了"才允许印 same=1/0，否则一律"未测" ---
#     ★为什么不用 rt_stage 当闸：STEPS=3/4 走完后 rt_stage 也会被改写成 98(那句"不建 /proc/不装载"的收尾)，
#       而那时 rt_same **已经算出来了** ⇒ 拿 stage∈{98,99} 判"未跑到往返"会把正结果误读成未测(自己造的第三种没牙)。
#       真正的分界是 rt_wr_rc：只有过了 policydb_write 它才是 0，裸 insmod 时它是 -1。
st=$(cat /sys/module/$MOD/parameters/rt_stage 2>/dev/null)
sm=$(cat /sys/module/$MOD/parameters/rt_same 2>/dev/null)
rp=$(cat /sys/module/$MOD/parameters/rt_prs_rc 2>/dev/null)
rd=$(cat /sys/module/$MOD/parameters/rt_rd_rc 2>/dev/null)
wr=$(cat /sys/module/$MOD/parameters/rt_wr_rc 2>/dev/null)
if [ "$wr" = "0" ] && { [ "$sm" = "1" ] || [ "$sm" = "0" ]; }; then
  if [ "$sm" = "1" ]; then
    echo "B2_VERDICT=判正(★空 delta 逐字节相同：pre=$(cat /sys/module/$MOD/parameters/rt_pre_len) wr=$(cat /sys/module/$MOD/parameters/rt_wr_len) nel=$(cat /sys/module/$MOD/parameters/rt_nel))" >> $L
  else
    echo "B2_VERDICT=判负(字节不等：same=$sm pre=$(cat /sys/module/$MOD/parameters/rt_pre_len) wr=$(cat /sys/module/$MOD/parameters/rt_wr_len) ⇒ 必须拉 WR 跑 w953b 出三元组四数)" >> $L
  fi
else
  echo "B2_VERDICT=未测(rt_wr_rc=$wr ⇒ 没走到我们那份 writer；查 stage=$st rd_rc=$rd prs_rc=$rp sym_rc=$(cat /sys/module/$MOD/parameters/rt_sym_rc) slab_rc=$(cat /sys/module/$MOD/parameters/rt_slab_rc))" >> $L
fi
sync

# --- 7) 拆干净 + ★活策略复证(装前装后两份 md5 相同＝我们没碰运行期策略) ---
rmmod $MOD
echo "rmmod_rc=$? mod_left=$(grep -c "^$MOD " /proc/modules)" >> $L
/system/bin/cat /sys/fs/selinux/policy > $POST
echo "POST_rc=$? post_bytes=$(wc -c < $POST) post_md5=$(md5sum $POST | cut -d' ' -f1)" >> $L
sync
if [ "$(md5sum $PRE | cut -d' ' -f1)" = "$(md5sum $POST | cut -d' ' -f1)" ]; then
  echo "POLICY_UNCHANGED=1(判据：运行期策略装前装后逐字节相同)" >> $L
else
  echo "[x] POLICY_UNCHANGED=0 ⇒ 装前装后不一样了，这是**大事**，立刻记进 DELIVERY 未通过项" >> $L
fi
chmod 666 $PRE $POST $L 2>/dev/null
echo "END up=$(cat /proc/uptime)" >> $L
chmod 666 $L
sync
