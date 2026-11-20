#!/system/bin/sh
# w1063_step2_slack_leg.sh —— 第 82 发：`rt_steps=2` × **`rt_slack_kb=64`** ⇒ 与第 81 发只差一件事：
#   喂给我们那份 `policydb_read` 的那 1.36 MB，**末尾多了 64 KB 余量**(填 0xA5)，而 `fp.len` 仍然＝len。
#
# ★这一格在问什么(§6.495/§6.498/§6.500 之后剩下的两族)：
#   第 81 发把死因收到 stage3＝我们那份 reader 解析这份导出；主机侧已判死"内核栈溢出"(上界 9632+992 < 16384)，
#   又给出"读序形状与设备那份逐项相同"(`policydb_read` 46/46)。所以现在只剩两族：
#     (甲)**越界读**：reader 在这串字节里读飘 ⇒ 飘出 vmalloc 的末尾就是守护页 ⇒ 当场 fault ⇒ 无 printk 的 PS_HOLD；
#     (乙)不是越界读(结构体错乱/我们自己的 slab/GFP/CFI 运行期/别的内核态环境)。
#   本腿就是 (甲) 的单变量判据：**给了余量还复位 ⇒ (甲)出局**(飘不出去也炸，说明不是"撞守护页")；
#                     **给了余量就活 ⇒ (甲)坐实**，而且下一步能拿"飘了多少字节"当量出来。
# ★四把身份证人(缺一不算这格)：`ARM=` ＋ `PARAM rt_steps=2` ＋ `PARAM rt_slack_kb=64` ＋ `PARAM rt_abi=82`
#   (`rt_abi` 是件号＝证明装载的是 v5_slack 那份而不是留在机器上的旧件；`ko_md5` 是另一把)。
# ★输入面自证：`rt_cp_same` 必须＝1(副本前 len 字节与原件同哈希)。＝0 ⇒ 我悄悄换了被测对象 ⇒ 全格未测。
# 结构上仍不写运行期策略：`do_load` 需要 0x4C4F4144 这把钥匙，本腿永远不传；装前装后各导一次活策略比 md5。
L=/data/local/tmp/w1063_step2_slack.out
K=/data/local/tmp/w986_polround_v5_slack.ko
MD5_EXPECT=2f95b23cc6cd5d55ba2939d892603618
MOD=w985_probe
WANT_STEPS=2
WANT_SLACK=64
WANT_ABI=82
PRE=/data/local/tmp/w1063_pol.pre
POST=/data/local/tmp/w1063_pol.post
: > $L
echo "BEGIN up=$(cat /proc/uptime) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)" >> $L
echo "ARM=传 rt_steps=$WANT_STEPS × rt_slack_kb=$WANT_SLACK(与第 81 发只差『解析用的缓冲区末尾有没有余量』) ko=$K expect=$MD5_EXPECT WANT_STEPS=$WANT_STEPS WANT_SLACK=$WANT_SLACK WANT_ABI=$WANT_ABI" >> $L
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

# --- 3) ★insmod：这一行本身先落证件再 sync(第 72 发的教训：致死步之前不许没留话) ---
echo "ARGV=insmod $K rt_steps=$WANT_STEPS rt_slack_kb=$WANT_SLACK" >> $L
sync
insmod $K rt_steps=$WANT_STEPS rt_slack_kb=$WANT_SLACK
RC=$?
echo "insmod_rc=$RC" >> $L
sync
INMOD=$(grep -c "^$MOD " /proc/modules)
if [ "$INMOD" = "1" ]; then
  echo "MODULES_LINE=$(grep "^$MOD " /proc/modules)" >> $L
else
  echo "[!!] /proc/modules 里没有 $MOD(计数=$INMOD) ⇒ 下面读不到参数是必然，别当通过" >> $L
fi

# --- 4) 参数面立刻抄件(rmmod 会连参数一起摘掉)；★三个臂证人都在这一段：steps/slack/abi ---
for f in rt_steps rt_slack_kb rt_abi rt_copy rt_cp_rc rt_cp_same rt_sum_cp do_load \
         rt_stage rt_sym_rc rt_slab_rc rt_rd_rc rt_prs_rc rt_wr_rc rt_load_rc \
         rt_pre_len rt_wr_len rt_same rt_ver rt_mls rt_nel rt_sum_pre rt_sum_wr rt_proc; do
  echo "PARAM $f=$(cat /sys/module/$MOD/parameters/$f 2>&1)" >> $L
done
sync

# --- 5) 装载期那几行 printk(dmesg 通道会吞，所以只当辅助证人，不当判据) ---
dg=$(dmesg 2>/dev/null | grep -ac 'w986')
echo "DMESG_w986_lines=$dg" >> $L
dmesg 2>/dev/null | grep -a 'w986' | tail -12 >> $L
sync

# --- 6a) 读数：一次把判据要用的量取进变量(判据块只碰变量，selftest 才好注入) ---
ST=$(cat /sys/module/$MOD/parameters/rt_stage 2>/dev/null)
STEPSR=$(cat /sys/module/$MOD/parameters/rt_steps 2>/dev/null)
SLKR=$(cat /sys/module/$MOD/parameters/rt_slack_kb 2>/dev/null)
ABI=$(cat /sys/module/$MOD/parameters/rt_abi 2>/dev/null)
COPY=$(cat /sys/module/$MOD/parameters/rt_copy 2>/dev/null)
CPRC=$(cat /sys/module/$MOD/parameters/rt_cp_rc 2>/dev/null)
CPSAME=$(cat /sys/module/$MOD/parameters/rt_cp_same 2>/dev/null)
CPH=$(cat /sys/module/$MOD/parameters/rt_sum_cp 2>/dev/null)
SYM=$(cat /sys/module/$MOD/parameters/rt_sym_rc 2>/dev/null)
SLAB=$(cat /sys/module/$MOD/parameters/rt_slab_rc 2>/dev/null)
LR=$(cat /sys/module/$MOD/parameters/rt_load_rc 2>/dev/null)
RD=$(cat /sys/module/$MOD/parameters/rt_rd_rc 2>/dev/null)
PLEN=$(cat /sys/module/$MOD/parameters/rt_pre_len 2>/dev/null)
PSUM=$(cat /sys/module/$MOD/parameters/rt_sum_pre 2>/dev/null)
PRS=$(cat /sys/module/$MOD/parameters/rt_prs_rc 2>/dev/null)
NEL=$(cat /sys/module/$MOD/parameters/rt_nel 2>/dev/null)
VER=$(cat /sys/module/$MOD/parameters/rt_ver 2>/dev/null)
MLS=$(cat /sys/module/$MOD/parameters/rt_mls 2>/dev/null)

# --- 6b) 判据(十支；臂证人从腿顶的三个 WANT_* 现取，selftest 也读同一份) ---
if [ "$INMOD" != "1" ]; then
  if [ "$RC" = "0" ]; then
    echo "NP_VERDICT=未测(insmod 报 0 但 /proc/modules 里没有它 ⇒ 读数自相矛盾，别当结论)" >> $L
  else
    echo "NP_VERDICT=判负(带 rt_steps=$WANT_STEPS/rt_slack_kb=$WANT_SLACK 也被拒 rc=$RC ⇒ 看装载回执原因)" >> $L
  fi
elif [ "$ABI" != "$WANT_ABI" ]; then
  echo "NP_VERDICT=未测(件号读回 rt_abi=$ABI ≠ $WANT_ABI ⇒ 装上去的不是这一版件，本发所有读数不算)" >> $L
elif [ "$STEPSR" != "$WANT_STEPS" ]; then
  echo "NP_VERDICT=未测(命令行给了 rt_steps=$WANT_STEPS 却读回 $STEPSR ⇒ parse_args 没写成，先查参数名)" >> $L
elif [ "$SLKR" != "$WANT_SLACK" ]; then
  echo "NP_VERDICT=未测(命令行给了 rt_slack_kb=$WANT_SLACK 却读回 $SLKR ⇒ **旋钮没拧上**，这一格根本没测到余量)" >> $L
elif [ "$ST" = "21" ]; then
  echo "NP_VERDICT=停在搬副本那步(stage=21, cp_rc=$CPRC ⇒ 十有八九是 vmalloc 1.36MB+64KB 没给下来，(甲)这一格未测)" >> $L
elif [ "$COPY" != "1" ]; then
  echo "NP_VERDICT=未测(旋钮拧上了却没吃副本 copy=$COPY cp_rc=$CPRC ⇒ 这一格量的还是原件)" >> $L
elif [ "$CPSAME" != "1" ]; then
  echo "NP_VERDICT=未测(★副本与原件哈希不同 cp_same=$CPSAME sum_pre=$PSUM sum_cp=$CPH ⇒ 我换了被测对象，别看后面)" >> $L
elif [ "$ST" = "99" ] && [ "$RD" != "0" ]; then
  echo "NP_VERDICT=未测(上游 stage2 就失败 rd_rc=$RD ⇒ 我们那份 reader 没被问到)" >> $L
elif [ "$ST" = "99" ] && [ "$PRS" = "0" ]; then
  echo "NP_VERDICT=判正(★给了 64KB 余量就解析得动：nel=$NEL ver=$VER mls=$MLS ⇒ **(甲)越界读坐实**：第 81 发是 reader 飘出 vmalloc 末尾撞守护页 ⇒ 下一步量『飘了多少字节』)" >> $L
elif [ "$ST" = "99" ]; then
  echo "NP_VERDICT=判负但形状变了(给了余量仍返回 prs_rc=$PRS ⇒ **(甲)出局**，且这次不是复位＝错误可读 ⇒ 抄 ver=$VER mls=$MLS nel=$NEL 离线对，压力给(乙)内核态环境族)" >> $L
elif [ "$ST" = "-1" ]; then
  echo "NP_VERDICT=未测(在册却 stage=-1 ⇒ init 体一步都没跑，与 insmod_rc=$RC 矛盾，先查仪器)" >> $L
else
  echo "NP_VERDICT=停在第 $ST 步(★未定位：sym=$SYM slab=$SLAB rd=$RD prs=$PRS cp_rc=$CPRC load=$LR ⇒ 对照源码看那一步是什么)" >> $L
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
