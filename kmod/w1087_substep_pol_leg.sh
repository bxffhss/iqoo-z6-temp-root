#!/system/bin/sh
# w1087_substep_pol_leg.sh —— 第 84 发：同一条路上只加两件**仪器**(§6.507/§6.508/§6.509)：
#   ①件＝v6_substep(`rt_abi=84`)——构建期由 `w1085_substep_patch.py` 往我们那份 `ss/policydb.c`/`ss/avtab.c` 的
#     读循环里**插纯赋值**(`rt_sub`＝走到第几段、`rt_idx`/`rt_idx2`＝那一段的循环下标)。它们不参与任何判断，
#     所以"被测"没变，变的只是"它死了以后还留不留得下位置"。
#   ②轮询器从"每 0.2 秒抄一行"改成**紧循环＋只在值变化时落盘**(`CHG` 行)，并每 2 万次读打一行 `HB`(证明它一直活着)。
#     第 83 发吃的就是节拍太粗的亏：tick 间隔 0.2 秒，机器根本没等到第二格。
#   ★读法看 `$P`：有 `CHG … sub=N` ⇒ 第一次拿到**带内的死亡位置**(N 对着补丁表读段名；这份树里没有 te_cond_avtab ⇒ 6 留空)；
#     一行 CHG 都没有而 `ko_md5`/`ARGV` 都在 ⇒ 那是对"init 期间参数面已可读"那条 module.c 顺序推断的**否证**，要落账。
#   ★判据块与 `w1063`/`w1069` 逐字相同(三份现抽块 md5 都是同一个)＝这一发只动仪器、不动判据；由总闸的 item 复证。
#
# ★为什么第 82 发白烧(§6.503)：判据那十二支全靠 `/sys/module/$MOD/parameters/*`，而**模块一死 sysfs 口就没了** ⇒
#   复位形状下 `rt_abi`/`rt_copy`/`rt_cp_same`/`rt_stage` 一个都读不回来 ⇒ "64 KB 余量真被吃到过"这句**没有证人**，
#   于是那一格既不能判 (甲) 也不能判 (乙)。**证人与被测同归于尽＝先天不可判。**
# ★这一版的解法(0 枪就在设备上验过形状的)：设备自己那份 `kernel/module.c` 里
#   `mod_sysfs_setup()`(第 4099 行，它调 `module_param_sysfs_setup` 建 parameters 那批文件)排在
#   `return do_init_module(mod)`(第 4115 行，`init` 体真正开跑)**之前** ⇒ **`init` 跑的时候参数面已经存在**。
#   ⇒ 本腿在 `insmod` 之前起一个**后台轮询子壳**，每 tick 把八支关键参数**逐字**抄进**另一个文件** `$P` 并 `sync`
#   (★一个文件只许一个写者＝§6.461：主壳只写 `$L`，子壳只写 `$P`)。机器若复位，`$P` 里已经落盘的那些行就是**死前读数**。
# ★轮询器自己也要有牙(例 210：仪器不许生产"0/缺")：开跑前先做 `SLEEP_PROOF`——量一次 `sleep $TICK` 前后的 `up`，
#   两次相同＝这台 toybox 不认小数睡眠 ⇒ 直接把节拍换成 1 秒再证一次，还不动就**明写 `POLL=skipped`**，不派一个忙轮询。
# ★复位后的四种读法(全部只看 `$P`，不许看 `$L` 有没有下一行)：
#   ①`$P` 里出现过 `copy=1 cpsame=1` ⇒ **副本确实被吃过**，于是"仍然复位"才第一次有资格说 (甲) 里"只飘一点点"那种不成立；
#   ②`$P` 里 `stage` 最高到过 2/21 但从未 `copy=1` ⇒ 死在搬副本那一步之前 ⇒ (甲) 那一格仍未测，凶器更靠前；
#   ③`$P` 一行 TICK 都没有而 `ko_md5`/`ARGV` 都在 ⇒ **参数面在 init 期间读不到**(我上面那条源码推断被否证) ⇒ 轮询器作废，
#     这一格照样是未测，但要**把否证写进账**(它值一发：下次别再照它设计腿)；
#   ④`$P` 里 `abi≠82` ⇒ 装上去的不是这一版件 ⇒ 全格未测(与 `$L` 的 `PARAM rt_abi` 互为独立两把读法)。
# ★四把身份证人：`ARM=` ＋ `PARAM rt_steps=2` ＋ `PARAM rt_slack_kb=64` ＋ `PARAM rt_abi=82`(＋ `$P` 每 tick 自带一份)。
# 结构上仍不写运行期策略：`do_load` 需要 0x4C4F4144 这把钥匙，本腿永远不传；装前装后各导一次活策略比 md5。
L=/data/local/tmp/w1087_substep_pol.out
P=/data/local/tmp/w1087_pol.txt
PE=/data/local/tmp/w1087_pol.err
K=/data/local/tmp/w986_polround_v6_substep.ko
MD5_EXPECT=d3d2175b73062358fc8b169df7ccb0b2
MOD=w985_probe
WANT_STEPS=2
WANT_SLACK=64
WANT_ABI=84
TICK=0.2
TICK_MAX=400000
HB_EVERY=20000
PRE=/data/local/tmp/w1069_pol.pre
POST=/data/local/tmp/w1069_pol.post
: > $L
: > $P
: > $PE
chmod 666 $L $P $PE 2>/dev/null
echo "BEGIN up=$(cat /proc/uptime) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)" >> $L
echo "ARM=传 rt_steps=$WANT_STEPS × rt_slack_kb=$WANT_SLACK(＝第 82 发那一格重打，只差『证人换个活法』) ko=$K expect=$MD5_EXPECT WANT_STEPS=$WANT_STEPS WANT_SLACK=$WANT_SLACK WANT_ABI=$WANT_ABI" >> $L
echo "POL_FILE=$P MODE=busy TICK_MAX=$TICK_MAX HB_EVERY=$HB_EVERY" >> $L
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
  #   模块还没起来的头几个 tick 必然九次读空 ⇒ 与其把它藏掉，不如**收到 $PE 里当证人**(它同时也是"参数面什么时候出现"的一手时刻)。
  (
    I=0
    LAST=""
    NREAD=0
    while [ "$I" -lt "$TICK_MAX" ]; do
      I=$((I+1))
      ST=""; SU=""; IX=""; I2=""; AB=""; CP=""; CS=""; RD=""; PR=""; SP=""
      read ST < /sys/module/$MOD/parameters/rt_stage 2>/dev/null
      read SU < /sys/module/$MOD/parameters/rt_sub 2>/dev/null
      read IX < /sys/module/$MOD/parameters/rt_idx 2>/dev/null
      read I2 < /sys/module/$MOD/parameters/rt_idx2 2>/dev/null
      read SP < /sys/module/$MOD/parameters/rt_steps 2>/dev/null
      read AB < /sys/module/$MOD/parameters/rt_abi 2>/dev/null
      read CP < /sys/module/$MOD/parameters/rt_copy 2>/dev/null
      read CS < /sys/module/$MOD/parameters/rt_cp_same 2>/dev/null
      read RD < /sys/module/$MOD/parameters/rt_rd_rc 2>/dev/null
      read PR < /sys/module/$MOD/parameters/rt_prs_rc 2>/dev/null
      KEY="${ST:-NA}/${SU:-NA}/${IX:-NA}/${I2:-NA}/${SP:-NA}/${AB:-NA}/${CP:-NA}/${CS:-NA}/${RD:-NA}/${PR:-NA}"
      # ★只在**值变了**的时候落盘＋sync：这样每 20000 次读才可能印一行，写量与 sync 次数都有界；
      #   而"最后一次变化"就是死前位置——第 83 发吃了"节拍太粗"的亏(两格之间 0.2 秒，机器根本没等到)。
      if [ "$KEY" != "$LAST" ]; then
        UP=""
        read UP < /proc/uptime 2>/dev/null
        echo "CHG $I up=${UP%% *} stage=${ST:-NA} sub=${SU:-NA} idx=${IX:-NA} idx2=${I2:-NA} steps=${SP:-NA} abi=${AB:-NA} copy=${CP:-NA} cp_same=${CS:-NA} rd=${RD:-NA} prs=${PR:-NA}" >> $P
        sync
        LAST="$KEY"
      fi
      NREAD=$((NREAD+1))
      if [ "$NREAD" -ge "$HB_EVERY" ]; then
        NREAD=0
        UP=""
        read UP < /proc/uptime 2>/dev/null
        echo "HB reads=$I up=${UP%% *} lastkey=$LAST" >> $P
        sync
      fi
    done
    echo "POL_END reads=$I" >> $P
    sync
  ) 2>>$PE &
  POLLPID=$!
  echo "POLL=busy pid=$POLLPID max_reads=$TICK_MAX hb=$HB_EVERY" >> $L
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
for f in rt_steps rt_slack_kb rt_abi rt_sub rt_idx rt_idx2 rt_copy rt_cp_rc rt_cp_same rt_sum_cp do_load \
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
