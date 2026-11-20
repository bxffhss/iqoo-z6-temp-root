#!/system/bin/sh
# w1093_hist_pol_leg.sh —— 第 85 发：第 84 发那一格原样重打，唯一变化＝**把记录搬进被测内部＋心跳换时间轴**(§6.510／例 215)。
#   ①件＝v7_substep(`rt_abi=85`)：v6 那三支段内计数器(`rt_sub`/`rt_idx`/`rt_idx2`)保留，**新增一条 48 项的环 `rt_hist`**——
#     构建期补丁插的语句从 `rt_sub = N;` 换成 `rt_sub = N; rt_note(N,…)`；`rt_stage` 的每一次换号也记一项。
#     环只有一个 `open+read` 的出口＝`/proc/w986_hist`，**整个环印在一行上**(设备那把 mksh 的内建 `read` 只吃一行，
#     且一次读一个文件＝零 fork)。
#   ②轮询器从"只在值变化时落盘"换成"**值变了或时间走过一整秒就落盘**"，每行自带 `I=`(读了多少轮)＋`up=`＋`bytes=`。
#     ★这一支是第 84 发那枚"三行之后没第四行"的解药：那一把尺的"活着"只能靠 `HB`(每 2 万次读)证，而"次数→秒"的
#     换算率由被测状态决定 ⇒ `HB` 缺席在两档速率下都不信息(读失败 0.36 ms/轮、读成功只要 ≥0.75 ms/轮)。
#     现在每一行自己就给出分母——**"没看到下一次变化"要么被时间轴否证，要么就是真没发生**。
#   ★环在被测里攒着，所以哪怕一秒只读一次，读到的也是**整条轨迹**：快过渡不再会被采样率跳过。
#
# ★读法(只看 `$P`，开枪前写死；这一版的分母由产物自己现印)：
#   ①出现带 `now_sub=N`/环里 `:N:` 的行 ⇒ **第一次拿到带内的死亡段**，N 对着 `w1085` 那张补丁表读段名
#     (`1 policydb_init｜2 policycaps｜3 permissive_map｜4 read_f[i] 第 i 张第 j 条｜5 te_avtab｜7 filename_trans｜
#      8 ocontext｜9 genfs｜10 range｜11 type_attr 的 ebitmap｜12 bounds_sanity_check`；★6 留空＝这份树没有 `te_cond_avtab`)。
#   ②环里最后几项停在 `stage=2`/`stage=21` ⇒ 死在搬副本那一步之前/之中，SS 的读循环根本没进。
#   ③一行 `SAMP` 都没有而 `ko_md5`/`ARGV` 都在 ⇒ 快照口在 init 期间读不到 ⇒ **对第 84 发那条已判正的"通道"再否定一次**，
#     要落账不许圆场(那次是参数面，这次是 `/proc` 口——两个面是两个独立结论)。
#   ④`bytes=0`/`hist=NA` 的行 ⇒ 口还没长出来；`TORN=1` ⇒ 那行是我撕裂读到的，只用来看形状、不当位置。
#   ⑤`abi≠85` ⇒ 装上去的不是这一版件 ⇒ 全格未测。
#   ★**不许**把任何读数读成"某族出局"，除非这一发真改变了那一行判断(§6.507 的规矩)。
#   ★分母自查(开枪后必做，不许跳)：把 `$P` 相邻两行的 `ΔI/Δup` 现算出来 ⇒ 得到"这一档每轮多少毫秒"；
#     有了它，"某段没出现在环里"才有资格说话。没有它，一切"没看到"＝未测。
#
# 结构上仍不写运行期策略：`do_load` 需要 0x4C4F4144 这把钥匙，本腿永远不传；装前装后各导一次活策略比 md5。
# ★判据块与 `w1063`/`w1069`/`w1087` **逐字相同**(四份现抽块 md5 都同一个)＝这一发只动仪器、不动判据；由总闸的 item 复证。
L=/data/local/tmp/w1093_hist_pol.out
P=/data/local/tmp/w1093_hist.txt
PE=/data/local/tmp/w1093_hist.err
K=/data/local/tmp/w986_polround_v7_substep.ko
MD5_EXPECT=20b15b11e43bd3b057d69d4b847c041a
MOD=w985_probe
WANT_STEPS=2
WANT_SLACK=64
WANT_ABI=85
TICK=0.2
TICK_MAX=200000
PRE=/data/local/tmp/w1093_pol.pre
POST=/data/local/tmp/w1093_pol.post
: > $L
: > $P
: > $PE
chmod 666 $L $P $PE 2>/dev/null
echo "BEGIN up=$(cat /proc/uptime) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)" >> $L
echo "ARM=传 rt_steps=$WANT_STEPS × rt_slack_kb=$WANT_SLACK(＝第 84 发那一格重打，唯一变化＝记录搬进被测＋心跳换时间轴) ko=$K expect=$MD5_EXPECT WANT_STEPS=$WANT_STEPS WANT_SLACK=$WANT_SLACK WANT_ABI=$WANT_ABI" >> $L
echo "POL_FILE=$P MODE=busy TICK_MAX=$TICK_MAX FACE=/proc/w986_hist" >> $L
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

# --- 2b) ★节拍自证，然后起后台轮询子壳(子壳只写 $P，主壳只写 $L＝一个文件一个写者 §6.461) ---
#   ★读数一律用 shell 内建 `read VAR < 文件`(＝**零 fork**)：这台机上我们自己的 fork 风暴有过记录(§6.198)，
#     60 个 tick 若每 tick fork 十次＝500 次派生进程，会把"仪器自己把机器搞死"这条混进被测。只留每 tick 一次 `sync`。
U0=$(cut -d' ' -f1 /proc/uptime)
sleep $TICK 2>/dev/null
U1=$(cut -d' ' -f1 /proc/uptime)
echo "SLEEP_PROOF tick=$TICK up0=$U0 up1=$U1" >> $L
if [ "$U1" = "$U0" ]; then
  TICK=1
  U2=$(cut -d' ' -f1 /proc/uptime)
  sleep 1
  U3=$(cut -d' ' -f1 /proc/uptime)
  echo "SLEEP_PROOF2 tick=1 up2=$U2 up3=$U3" >> $L
  [ "$U3" = "$U2" ] && TICK=SKIP
fi
if [ "$TICK" != "SKIP" ]; then
  # ★0 枪预检(w1071)现学到一条设备 shell 的脾气：`read VAR < 不存在的文件 2>/dev/null` **仍然会**把
  #   "can't open …" 打在 **终端 stderr** 上(那是**外壳**在重定向失败时报的，`read` 自己的 2>/dev/null 管不着)。
  #   模块还没起来的头几轮必然读空 ⇒ 不藏掉，**收进 $PE 当证人**(它给出"快照口什么时候出现的"一手时刻)。
  (
    I=0
    W=0
    LASTH=""
    LASTSEC=""
    while [ "$I" -lt "$TICK_MAX" ]; do
      I=$((I+1))
      H=""
      read H < /proc/w986_hist 2>/dev/null
      UP=""
      read UP < /proc/uptime 2>/dev/null
      SEC=${UP%% *}
      SEC=${SEC%.*}
      # ★落盘两支(缺一个这发就白打)：①**轨迹变了**(值证人)；②**时间走过一整秒**(活着的证人＋分母证人，例 215)。
      #   为什么这次敢"每轮都带着 `I=`(读的次数)＋`up=`"：写出的每一行自己就给出"这段时间里我读了多少轮"，
      #   于是"没看到下一次变化"要么被时间轴否证、要么就是真没发生——**不再需要一个换算率未知的次数轴心跳**。
      #   环在被测里已经攒着(48 项)，所以哪怕一秒才读一次，读到的也是**整条轨迹**，快过渡跳不过去。
      if [ "$H" != "$LASTH" ] || [ "$SEC" != "$LASTSEC" ]; then
        echo "SAMP $I up=${UP%% *} since_w=$W bytes=${#H} hist=${H:-NA}" >> $P
        sync
        W=0
        LASTH="$H"
        LASTSEC="$SEC"
      else
        W=$((W+1))
      fi
    done
    echo "POL_END reads=$I" >> $P
    sync
  ) 2>>$PE &
  POLLPID=$!
  echo "POLL=busy pid=$POLLPID max_reads=$TICK_MAX cadence=值变化或每过一整秒 sync每行" >> $L
else
  echo "POLL=skipped(不该发生：紧循环不依赖睡眠)" >> $L
fi
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
for f in rt_steps rt_slack_kb rt_abi rt_sub rt_idx rt_idx2 rt_seq rt_hist_next rt_hist_proc rt_copy rt_cp_rc rt_cp_same rt_sum_cp do_load \
         rt_stage rt_sym_rc rt_slab_rc rt_rd_rc rt_prs_rc rt_wr_rc rt_load_rc \
         rt_pre_len rt_wr_len rt_same rt_ver rt_mls rt_nel rt_sum_pre rt_sum_wr rt_proc; do
  echo "PARAM $f=$(cat /sys/module/$MOD/parameters/$f 2>&1)" >> $L
done
sync

# --- 4b) 收轮询子壳＋现数它的形状(条数由这条自己数，不手数；**这里只印原始读数，不印派生结论**) ---
if [ "$TICK" != "SKIP" ]; then
  kill $POLLPID 2>/dev/null
  echo "POLL_STOP kill_rc=$? ticks=$(wc -l < $P 2>/dev/null)" >> $L
else
  echo "POLL_STOP 没有子壳要收(POLL=skipped)" >> $L
fi
echo "POLL_LAST=$(tail -1 $P 2>/dev/null)" >> $L
echo "POLL_BYTES=$(wc -c < $P 2>/dev/null)" >> $L
echo "POLL_ERR_BYTES=$(wc -c < $PE 2>/dev/null) POLL_ERR_TAIL=$(tail -1 $PE 2>/dev/null)" >> $L
chmod 666 $P $PE 2>/dev/null
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
chmod 666 $PRE $POST $L $P 2>/dev/null
sync
