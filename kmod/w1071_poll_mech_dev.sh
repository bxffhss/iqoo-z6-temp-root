#!/system/bin/sh
# w1071_poll_mech_dev.sh —— 0 枪的**机制预检**：第 83 发那条腿要拿"后台轮询器"当复位后唯一的证人通道，
#   所以三件事必须在**不装载任何模块**的情况下先证会动(例 206：先证明仪器会红/会动，再拿它的读数说话)：
#     ①这台 toybox 认不认**小数睡眠**(`sleep 0.2` 真等了吗)——不认 ⇒ 轮询器就变成忙轮询，fork/sync 会把仪器自己的账混进被测；
#     ②`read VAR < 文件` 在设备 mksh 上取得到值吗(我们要**零 fork** 地读 sysfs，不用 `cat`)；
#     ③一行 TICK 的形状与 `${UP%% *}`(把 `/proc/uptime` 两个数里第一个切出来)对不对；
#     ④(第 85 发新增)一条**约 1 KB 的单行**能不能被内建 `read` 整行读回不截断——`/proc/w986_hist` 把整个环印在一行上。
#   做法：造一个假的"参数目录"(与 /sys/module/<mod>/parameters 同形状)＋一份长行件，用**与腿里完全一样的读法**跑 N 个 tick。
#   ★不碰 /sys/fs/selinux/*、不 insmod、不要求 root ⇒ 基线态也能跑。
D=/data/local/tmp/w1071_mech
P=$D/tick.txt
MODDIR=$D/fakemod/parameters
N=6
TICK=0.2
rm -rf $D 2>/dev/null
mkdir -p $MODDIR
: > $P
echo "MECH_BEGIN up=$(cut -d' ' -f1 /proc/uptime) n=$N tick=$TICK dir=$MODDIR" > $P
# --- 1) 造假参数面：九个名字与腿里读的那九个**一字不差** ---
for f in rt_stage rt_steps rt_abi rt_slack_kb rt_copy rt_cp_rc rt_cp_same rt_rd_rc rt_prs_rc; do
  echo "7" > $MODDIR/$f
done
echo "MADE files=$(ls $MODDIR | wc -l)" >> $P
# --- 2) ①小数睡眠：量 sleep 前后的 up，必须**变**(不动就换 1 秒再证一次) ---
U0=$(cut -d' ' -f1 /proc/uptime)
sleep $TICK 2>/dev/null
U1=$(cut -d' ' -f1 /proc/uptime)
echo "SLEEP_PROOF tick=$TICK up0=$U0 up1=$U1 same=$([ "$U1" = "$U0" ] && echo YES || echo NO)" >> $P
TICK_EFF=$TICK
if [ "$U1" = "$U0" ]; then
  TICK_EFF=1
  U2=$(cut -d' ' -f1 /proc/uptime)
  sleep 1
  U3=$(cut -d' ' -f1 /proc/uptime)
  echo "SLEEP_PROOF2 tick=1 up2=$U2 up3=$U3 same=$([ "$U3" = "$U2" ] && echo YES || echo NO)" >> $P
  [ "$U3" = "$U2" ] && TICK_EFF=SKIP
fi
# --- 3) ②③与腿里同一段读法：内建 read(零 fork)＋NA 兜底＋同一行形状 ---
I=0
while [ "$I" -lt "$N" ]; do
  I=$((I+1))
  UP=""; ST=""; AB=""; SL=""; CP=""; CR=""; CS=""; RD=""; PR=""; SP=""
  read UP < /proc/uptime 2>/dev/null
  read ST < $MODDIR/rt_stage 2>/dev/null
  read SP < $MODDIR/rt_steps 2>/dev/null
  read AB < $MODDIR/rt_abi 2>/dev/null
  read SL < $MODDIR/rt_slack_kb 2>/dev/null
  read CP < $MODDIR/rt_copy 2>/dev/null
  read CR < $MODDIR/rt_cp_rc 2>/dev/null
  read CS < $MODDIR/rt_cp_same 2>/dev/null
  read RD < $MODDIR/rt_rd_rc 2>/dev/null
  read PR < $MODDIR/rt_prs_rc 2>/dev/null
  echo "TICK $I up=${UP%% *} stage=${ST:-NA} steps=${SP:-NA} abi=${AB:-NA} slack=${SL:-NA} copy=${CP:-NA} cp_rc=${CR:-NA} cp_same=${CS:-NA} rd=${RD:-NA} prs=${PR:-NA}" >> $P
  sync
  [ "$TICK_EFF" != "SKIP" ] && sleep $TICK_EFF
done
# --- 3b) ★第 85 发那一格新增：**长行**读取(快照读点把整个环印在一行上，实测约 700~1000 字节)。
#         内建 `read` 会不会把长行截掉/只吃半行？造一条已知长度的单行文件，读回来**现数**，必须＝写进去的数。
#         ★这一格承重：若 `read` 截行，那么 `$P` 里 `bytes=` 小的那些行就是**我的读法在吃半条轨迹**，
#           而不是"环里只有那么多项"——没这一格，"末项停在 N 段"那枚读数根本不能算(例 210：仪器不许自己生产"缺")。
LONG=""
KI=0
while [ "$KI" -lt 100 ]; do LONG="${LONG}abcdefghij"; KI=$((KI+1)); done
printf '%s\n' "$LONG" > $D/longline
read LL < $D/longline 2>/dev/null
LW=${#LONG}; LG=${#LL}
echo "LONGREAD wrote=$LW got=$LG head=$(printf %.10s "$LL") tail=$(printf %s "$LL" | tail -c 11)" >> $P
# --- 4) 判据：①睡眠走动 ②九个值全读得到(不许一个 NA) ③tick 数对得上 ④末行 up 晚于首行 up ⑤长行没被截 ---
TN=$(grep -ac '^TICK ' $P)
NA=$(grep -a '^TICK ' $P | grep -c 'NA')
# ★上一版这里是 `tail -1 $P`——我把"长行那一格"(3b)插到判据之前之后，`tail -1` 就不是最后一行 TICK 了，
#   于是 `last_up` 解析成空 ⇒ `MECH_RC=1`。**红得对**(仪器自己抓住自己的改动)，但抓的是我：判据要**按行类型取**，不能按"文件的最后一行"取。
LAST=$(grep -a '^TICK ' $P | tail -1)
FIRSTUP=$(grep -a '^TICK ' $P | head -1 | sed -n 's/.*up=\([0-9.]*\).*/\1/p')
LASTUP=$(printf '%s\n' "$LAST" | sed -n 's/.*up=\([0-9.]*\).*/\1/p')
echo "MECH ticks_want=$N ticks_got=$TN na_lines=$NA tick_eff=$TICK_EFF first_up=$FIRSTUP last_up=$LASTUP" >> $P
RC=0
[ "$TN" = "$N" ] || { echo "MECH_FAIL=条数不对($TN≠$N)" >> $P; RC=1; }
[ "$NA" = "0" ] || { echo "MECH_FAIL=有 NA($NA 行)⇒ 内建 read 取不到值" >> $P; RC=1; }
[ "$LG" = "$LW" ] || { echo "MECH_FAIL=长行被截(got=$LG ≠ wrote=$LW)⇒ 快照读点那条腿要换读法" >> $P; RC=1; }
case "$FIRSTUP" in ''|*[!0-9.]*) echo "MECH_FAIL=首行 up 解析不出(形状坏)" >> $P; RC=1 ;; esac
case "$LASTUP" in ''|*[!0-9.]*) echo "MECH_FAIL=末行 up 解析不出(形状坏)" >> $P; RC=1 ;; esac
if [ "$FIRSTUP" = "$LASTUP" ]; then echo "MECH_FAIL=整段轮询期间 up 一字没变⇒节拍没延时" >> $P; RC=1; fi
# --- 4b) ★负对照(例 194：只测"会放行"的那格不算判据)：从**不存在的目录**读，变量必须取不到值(空⇒印 NA)。
#         若这里居然取到了值，上面那句"na_lines=0"就是空判据——我根本不知道 NA 长什么样。
read XX < $D/no_such_dir/rt_stage 2>/dev/null
[ -n "${XX:-}" ] && { echo "MECH_FAIL=负对照居然读到值(XX=$XX)⇒ 上面那条『没有 NA』没有牙" >> $P; RC=1; } \
  || echo "MECH_NEG=不存在的文件读出来是空(NA 分支确实可达)" >> $P
echo "MECH_RC=$RC(0＝轮询器这套读法在这台机上会动，含 1 KB 单行不截；非 0＝这一发不许拿它当证人)" >> $P
chmod 666 $P 2>/dev/null
sync
