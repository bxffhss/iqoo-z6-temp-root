#!/bin/bash
# w1143_bprime_chain.sh —— 第 96 发＝#237(B′)：**模块侧**把一份整图交给 security_load_policy，这台机收不收。
#
# 问的只有一格(95 发已经把"运行期整图装载"经 selinuxfs 判正了，这一发换的是**入口**)：
#   外部模块直接调设备的 `security_load_policy(state, buf, len)`，
#   ①会不会像第 81~85 发那样把机器打死；②收下之后台上那张图是不是我们交进去的那张。
#   ★它**不答**"社区模块能装"(那堵墙＝厂商类型表里没有 nsfs，§6.525/§6.528 的"口径不许越线")，
#   ★也**不宣称**与写 /sys/fs/selinux/load 全等价：我们不调 sel_make_policy_nodes()、不持 fsi->mutex。
#
# 三道闸(都在件里，链只负责把值传对)：insmod 期 `pl_key='POLD'` ｜ `ARM <FNV>`＋GO 当下重读重比 ｜ 尺寸/魔数。
# 两种图(MODE)：
#   round(默认) ＝ 把**设备自己导出的那份**(钉死的厂商件)原样交回去 ⇒ 语义不变，只答"模块侧这条路通不通、会不会冻"；
#   delta       ＝ 交调用方给的 `<img> <md5> <bytes>` 三件套 ⇒ 顺带答"新类型进没进决策路径"(#236 那一格)。
#
# ★读法(开枪前写死，七条，不许互相顶替)：
#   ① 没等到腿件里的 `END up=` ⇒ **未测**(机器可能死在 GO 那一刻；那本身是信息，但要按 bootreason＋采样器另记)。
#   ② `post_why=1/2/3/4/5/6/7` ⇒ 闸拦住了(没钥匙/符号没齐/没图/太小/太大/魔数或串长不对) ⇒ **未测**，不是"被内核拒"。
#   ③ `post_why=8` ⇒ 活策略与 ARMBASE 不符 ⇒ 装载面不对 ⇒ **未测**(这一发没有被测被执行)。
#   ④ `post_why=11` ⇒ 甲那把尺(security_read_policy)自己就红了 ⇒ **未测**。
#   ⑤ `post_load_rc≠0`(且 why=0) ⇒ **模块侧装载被内核拒**＝这一格的答案(负结果)，看 rc 定性质。
#   ⑥ `post_load_rc=0` 但 甲不齐(post_len≠img_len ／ post_sum≠PC 那份 pol.after 的 FNV ／ same_as_staged≠1)
#      ⇒ 记"收了但没核到图"，不许写"装上了"。
#   ⑦ 乙按 MODE 走：round 要求 `rc_pre == rc_post`(同一张图，前后都该同一结果)且 `kc_pre/kc_post` **都是 0**
#      (现成标签全程解得开＝那把尺有牙)；delta 要求 `kc_pre=kc_post=0` 且 `rc_pre≠0 且 rc_post=0`。
#      任何一侧出现 `RES_SKIP=-1000` ⇒ 那一格按未测(参数没传，不是解不开)。
#
# ★★这一发会改**运行期安全策略**(等价于一次策略装载)，且量产机不可留窗过夜：
#   要 `APPROVE=<今天日期>` ＋ `I_KNOW=1` 两个显式钥匙，缺一就只跑到铺件那步(第 1~5 步，0 枪)就停。
#   收尾固定 `adb reboot` 并复核基线(策略只在内存里，重启即回厂商图；探针件在 /data/local/tmp 里由链自己删净并复证)。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT=${SHOT:-96}
MODE=${MODE:-round}
DDEV=/data/local/tmp/w1142
LEGREPO=kmod/w1142_polload_leg.sh
LEGDEV=$DDEV/w1142_polload_leg.sh
LEGOUT=$DDEV/leg.out
KO_REPO=kmod/w103_evidence/z6polload_v1.ko
KO_DEV=$DDEV/z6polload.ko
VENDOR_MD5=282a68611a2f36321a153fc0102f9ca0
VENDOR_BYTES=1356948
VENDFILE=$EV/w1117_pol.orig_94
HIST_KERNEL_FNV=5457979107816203493	# #219 那发设备上内核自己印的 rt_sum_pre(同一把尺的另一端)
KEYDEC=1347374148
NEWTYPE=${NEWTYPE:-z6_probe_file}
CTL=$DDEV/ctl.txt
CONSOLE=$EV/w1143_shot${SHOT}_console.txt	# ★由 `bash kmod/w1143_bprime_chain.sh 2>&1 | tee <此件>` 生成
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
RM_CLI=hermes-remote1/cli.py; RM_CFG=hermes-remote1/config.json
RPUSH() { HRMT_CLI=$RM_CLI python $RM_CLI --config $RM_CFG put "$1" "$2" 2>&1 | tail -1; }
REXEC() { HRMT_CLI=$RM_CLI W682_T=400 PYTHONUTF8=1 python kmod/w682_rr.py "$1" 2>&1 | tr -d '\r'; }
# ★结构尺那把二进制＝第 95 发用的同一枚(对表才可比)；不在／不等 ⇒ 甲记**未测**，不许拿"没跑"当"过了"
AF_BIN_MD5=56bb67e3414eecd2c6b4c0e64050bbb6
AF_RULER=kmod/w1131_after_newtype_remote.sh

if [ -n "${MSYS_NO_PATHCONV+set}" ]; then echo "[x] MSYS_NO_PATHCONV 被定义了(哪怕空值) ⇒ 拒跑(它会让离线自测假红；见例 218)"; exit 3; fi

echo "[1/7] 离线总闸(链内现跑)＋陈旧源码闸"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪(红的是闸就补前置，不是改闸)"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

echo "[2/7] 现值(不背历史)＋两把尺同源的现证"
KOM=$(md5sum $KO_REPO | cut -d' ' -f1); LMM=$(md5sum $LEGREPO | cut -d' ' -f1)
echo "  ko=$KOM 腿=$LMM 模式=$MODE"
[ -s "$KO_REPO" ] || { echo "[x] 探针件不在仓库 ⇒ 不开窗"; exit 1; }
case "$MODE" in
  round) IMG_SRC=$VENDFILE; EXP_MD5=$VENDOR_MD5; EXP_BYTES=$VENDOR_BYTES ;;
  delta) IMG_SRC=${1:-}; EXP_MD5=${2:-}; EXP_BYTES=${3:-}
         [ -n "$IMG_SRC" ] && [ -s "$IMG_SRC" ] || { echo "[x] delta 模式要给 <img> <md5> <bytes> ⇒ 停"; exit 1; }
         [ ${#EXP_MD5} = 32 ] || { echo "[x] 期望 md5 不是 32 位hex ⇒ 停(拿不到期望值就不许开窗)"; exit 1; }
         case "$EXP_BYTES" in ''|*[!0-9]*) echo "[x] 期望 bytes 不是十进制数 ⇒ 停"; exit 1 ;; esac ;;
  *) echo "[x] MODE 只认 round/delta(给的是[$MODE]) ⇒ 停"; exit 2 ;;
esac
IM=$(md5sum "$IMG_SRC" | cut -d' ' -f1); IB=$(wc -c <"$IMG_SRC" | tr -dc '0-9')
echo "  图现读：$IMG_SRC = $IB B md5=$IM  (期望 $EXP_BYTES/$EXP_MD5)"
[ "$IM" = "$EXP_MD5" ] && [ "$IB" = "$EXP_BYTES" ] || { echo "[x] 图与期望不符 ⇒ 不开窗(输入面就错了)"; exit 1; }
FN_VEND=$(PYTHONUTF8=1 python kmod/w1047_fnv64.py "$VENDFILE" | sed -n 's/^FNV64_SRC_SEED=\([0-9]*\).*/\1/p')
if [ "$IMG_SRC" = "$VENDFILE" ]; then ARMBASE=$FN_VEND; else
  ARMBASE=$(PYTHONUTF8=1 python kmod/w1047_fnv64.py "$IMG_SRC" | sed -n 's/^FNV64_SRC_SEED=\([0-9]*\).*/\1/p')
fi
echo "    厂商件 FNV(源种子)=$FN_VEND ｜ 要武装的 ARMBASE=$ARMBASE"
[ -n "$ARMBASE" ] || { echo "[x] ARMBASE 取到空串 ⇒ 停(例 222 那一族：空≠0)"; exit 1; }
echo "  ★尺同源现证：PC 算厂商件＝$FN_VEND ／ #219 设备上内核自己印＝$HIST_KERNEL_FNV"
[ "$FN_VEND" = "$HIST_KERNEL_FNV" ] || { echo "[x] 两把尺不同源 ⇒ **不开窗**(那 pre_sum 就没法比，甲尺整体作废)"; exit 1; }
echo "  ARMBASE(＝要武装的那把基线指纹)=$ARMBASE"

echo "[3/7] 设备侧只读基线＋清上一 boot 的同名残留(★只读；派腿前必须复证已删)"
# ★★设备侧的 `$(…)` 必须**原样送到设备上求值**：写成 A "echo UP=$(cut …)" 会在**本机**展开——
#   我第一次 dry run 就是这么印出 `UP=10487.64`(那是我台式机的 uptime！)而 KERNELSU/BOOT/POL 全空。
#   空还好办(判据会红)，**别的机器的数当成这台机的读数**才是最坏那种。⇒ 命令串放单引号变量里。
BASE='getenforce; echo KERNELSU=$(grep -c "^kernelsu " /proc/modules 2>/dev/null); echo BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null); echo UP=$(cut -d" " -f1 /proc/uptime 2>/dev/null); echo ENFN=$(cat /sys/fs/selinux/enforce 2>/dev/null); echo WHO=$(id -u 2>/dev/null)'
# ★故意**不**拿 `stat -c %s /sys/fs/selinux/policy` 当"活策略尺寸"的证人：现读它就是 0
#   (sysfs 那个 inode 的 i_size 只在 sel_open_policy 里被写；没人开着时是 0)。1,356,948 那个数要从
#   导出的件本身拿(腿里 pol.before 的字节数＝链里的 before_bytes 格)。
B0=$(A "$BASE")
echo "$B0" | sed 's/^/    /'
grep -q '^BOOT=[0-9a-f-]\{8,\}' <<<"$B0" || { echo "[x] 设备没把 boot_id 报回来(多半又是本机展开) ⇒ 不开窗"; exit 1; }
grep -q '^UP=[0-9]\+' <<<"$B0" || { echo "[x] 设备 uptime 读数空 ⇒ 不开窗"; exit 1; }
A "rm -rf /data/local/tmp/w1142" >/dev/null
GONE=$(A "ls -d $DDEV 2>&1"); echo "  复证已删：$GONE"
case "$GONE" in *"No such file"*) : ;; *) echo "[x] 残留目录删不掉 ⇒ **不开窗**(派了就是把陈件当读数)"; exit 1 ;; esac

echo "[4/7] 铺件＋五把闸(x 位／plain s0／两端 md5／设备 mksh sh -n／图在设备上的 md5 也现比)"
A "mkdir -p $DDEV" >/dev/null
MSYS_NO_PATHCONV=1 adb push "$IMG_SRC" $DDEV/img.bin 2>&1 | tail -1 | sed 's/^/  push img : /'
MSYS_NO_PATHCONV=1 adb push "$KO_REPO" $KO_DEV     2>&1 | tail -1 | sed 's/^/  push ko  : /'
MSYS_NO_PATHCONV=1 adb push "$LEGREPO" $LEGDEV     2>&1 | tail -1 | sed 's/^/  push leg : /'
A "printf 'IMG=%s\nKO=%s\nARMBASE=%s\nCTX=u:object_r:%s:s0\nCTRL=u:object_r:shell_data_file:s0\nKEYDEC=%s\nCAP=8388608\nOUT=%s\n' $DDEV/img.bin $KO_DEV $ARMBASE $NEWTYPE $KEYDEC $LEGOUT > $CTL; chmod 666 $CTL $DDEV/img.bin $KO_DEV; chmod 755 $LEGDEV; cat $CTL" | sed 's/^/  ctl: /'
# ★腿要 755(不是 666)：§6.474 那一发就是 `adb push` 落 0666 把 uid 0 挡在 execve 外面(rc=126)。
#   我第一次 dry run 里就是这条闸把这种空枪拦在了开窗之前——它红的是我的铺件顺序，不是被测。
P=$(A "ls -l $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}'); LB=$(A "ls -Zd $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}')
LM2=$(A "md5sum $LEGDEV 2>/dev/null" | cut -d' ' -f1); KM2=$(A "md5sum $KO_DEV 2>/dev/null" | cut -d' ' -f1)
IM2=$(A "md5sum $DDEV/img.bin 2>/dev/null" | cut -d' ' -f1)
S=$(MSYS_NO_PATHCONV=1 adb shell "/system/bin/sh -n $LEGDEV >/dev/null 2>&1 && echo SHN=OK || echo SHN=BAD" 2>&1 | tr -d '\r')
echo "  腿 权限=$P 标签=$LB 设备md5=$LM2 本机md5=$LMM $S"
echo "  ko 设备md5=$KM2 本机md5=$KOM ｜ img 设备md5=$IM2 本机md5=$IM"
[ "${P:3:1}" = x ] || { echo "[x] 腿件没 x 位 ⇒ 不开窗(§6.474：rc=126 那种空枪)"; exit 1; }
case "$LB" in *:s0) : ;; *) echo "[x] 腿件标签不是 plain s0 ⇒ 不开窗(#114)"; exit 1 ;; esac
[ "$LM2" = "$LMM" ] || { echo "[x] 设备上不是本机这支腿 ⇒ 不开窗"; exit 1; }
[ "$KM2" = "$KOM" ] || { echo "[x] 设备上不是本机这枚探针 ⇒ 不开窗"; exit 1; }
[ "$IM2" = "$IM" ]  || { echo "[x] 设备上的图与本机不同(push 没忠实到位) ⇒ 不开窗"; exit 1; }
grep -q SHN=OK <<<"$S" || { echo "[x] 腿没过设备语法闸 ⇒ 不开窗"; exit 1; }
A "ls -l $LEGOUT 2>&1" | grep -q 'No such file' || { echo "[x] 腿的 out 件已存在且删不掉 ⇒ 不开窗"; exit 1; }

if [ "${APPROVE:-}" != "$(date +%F)" ]; then
  echo "[5/7] ★**没给今天的 APPROVE=<$(date +%F)> ⇒ 到此为止(0 枪)**。第 6~7 步会改运行期安全策略，要现场点头。"
  echo "      上面四步已把两件＋图铺好并五把闸全过；不复证的东西一律不算(所以这段只当'待开枪状态')。"
  A "rm -rf $DDEV" >/dev/null; echo "      已撤场：$(A "ls -d $DDEV 2>&1")"
  exit 0
fi

echo "[6/7] ★开窗(1 枪＝punch)＋派这一发唯一的那条腿"
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 还要 I_KNOW=1"; exit 2; }
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LMM" LEG1ONLY=1 I_KNOW=1 NOFIRE="${NOFIRE:-}" bash kmod/go.sh > $EV/w1143_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1143_shot${SHOT}_go.log | sed 's/^/  go: /'
READY=0; ROUND=0
for i in $(seq 1 100); do ROUND=$i
    B=$(A "grep -acF 'LEG_BEGIN' $LEGOUT 2>/dev/null" | tr -dc '0-9')
    E=$(A "grep -acF 'END up=' $LEGOUT 2>/dev/null" | tr -dc '0-9')
    if [ "${B:-0}" -ge 1 ] && [ "${E:-0}" -ge 1 ]; then READY=1; echo "  腿跑完(第 $i 轮：BEGIN 与 END 齐)"; break; fi
    [ "${B:-0}" = 0 ] && [ "${E:-0}" -ge 1 ] && echo "  [!] 第 $i 轮：有 END 没 BEGIN ⇒ 陈件，继续等真这一份"
    sleep 3
done
[ "$READY" = 1 ] || echo "  [!] 等满 $ROUND 轮没等到两行 ⇒ **未测**(读法①：'没输出'既不当通过也不当被拒)"
A "cat $LEGOUT 2>/dev/null" > $EV/w1143_leg_shot${SHOT}.out 2>&1
B1=$(A "cat /proc/sys/kernel/random/boot_id 2>&1")
LB0=$(sed -n 's/^LEG_BEGIN up=\([0-9]*\) boot_id=\([0-9a-f-]*\).*/\2/p' $EV/w1143_leg_shot${SHOT}.out 2>/dev/null | head -1)
echo "  boot 身份：腿自印=$LB0 go.sh 返回后读回=$B1 $( [ -n "$LB0" ] && [ "$LB0" = "$B1" ] && echo '⇒ 相等＝这条腿跑在我们正在读的这扇窗里' || echo '**不相等⇒这一格未测**' )"
MSYS_NO_PATHCONV=1 adb pull $DDEV $EV/w1143_records_shot${SHOT} 2>&1 | tail -1 | sed 's/^/  pull: /'
grep -aE 'LEG_(BEGIN|enf|export_rc|insmod_rc|mod_seen|pre_(abi|sym_rc|proc|key|cap|why|armed)|GATE1|ARM_written|stage_(img_len|img_sum|img_wvers|writes|why)|staged_rc|GO_AT|post_(why|load_rc|pre_len|pre_sum|post_len|post_sum|rc_pre|rc_post|kc_pre|kc_post)|staged_eq_live|alive|rmmod_rc|END)' $EV/w1143_leg_shot${SHOT}.out | sed 's/^/    /'

echo "[7/7] 判读(甲＝结构尺＋三把独立来源；乙＝行为尺，按 MODE)＋收尾 reboot 复核"
g() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" $EV/w1143_leg_shot${SHOT}.out 2>/dev/null | head -1; }
# ★★取数要先**锚到那一条行**再取键：`g armed` 会命中更早那一行的 `pre_armed=`(装载前它本来 -1)，
#   于是"没武装"这个假象被我当读数印进了证件——同一个键在三个阶段各出现一次＝例 222 那一族，
#   第 95 发我在 `AF_TYPES` 上犯过，这一发在 `armed` 上又犯。⇒ 阶段性的键一律用 gl <行锚> <键>。
gl() { sed -n "/$1/!d;s/.*$2=\([^ ]*\).*/\1/p" $EV/w1143_leg_shot${SHOT}.out 2>/dev/null | head -1; }
WHY=$(g post_why); LRC=$(g post_load_rc); PLEN=$(g post_pre_len); QLEN=$(g post_post_len)
PSUM=$(g post_pre_sum); QSUM=$(g post_post_sum); ISUM=$(g stage_img_sum); ILEN=$(g stage_img_len)
RCP=$(g post_rc_pre); RCS=$(g post_rc_post); KCP=$(g post_kc_pre); KCS=$(g post_kc_post)
KSIDP=$(g post_ksid_pre); KSIDS=$(g post_ksid_post); WVERS=$(g post_img_wvers)
EQS=$(g staged_eq_live); ARMp=$(g ARM_written)
ARW=$(gl 'ARM_written' arm_want); ARL=$(gl 'ARM_written' arm_live); ARD=$(gl 'ARM_written' armed); ARD2=$(g post_armed)
BEF=$(sed -n 's/.*before_md5=\([0-9a-f]\{32\}\).*/\1/p' $EV/w1143_leg_shot${SHOT}.out | head -1)
BBY=$(sed -n 's/.*before_bytes=\([0-9]*\).*/\1/p' $EV/w1143_leg_shot${SHOT}.out | head -1)
LIVE=$(md5sum $EV/w1143_records_shot${SHOT}/pol.before 2>/dev/null | cut -d' ' -f1)
AFT=$(md5sum $EV/w1143_records_shot${SHOT}/pol.after 2>/dev/null | cut -d' ' -f1)
STG=$(md5sum $EV/w1143_records_shot${SHOT}/pol.staged 2>/dev/null | cut -d' ' -f1)
F2=$(PYTHONUTF8=1 python kmod/w1047_fnv64.py $EV/w1143_records_shot${SHOT}/pol.after 2>/dev/null | sed -n 's/^FNV64_SRC_SEED=\([0-9]*\).*/\1/p' | head -1)
echo "    腿自报 before_md5=$BEF before_bytes=$BBY ｜ 拉回的 pol.before=$LIVE(厂商钉死=$VENDOR_MD5) ｜ pol.staged=$STG"
echo "    字节面：输入 $IM ／ 内核装完再导出的那份 $AFT $( [ "$AFT" = "$IM" ] && echo 相同 || echo '(不同＝预期的：序列化不是不动点，见下)' )"
echo "    FNV 两条独立路径：PC 算 after＝$F2 ／ 内核印 post_sum＝$QSUM $( [ -n "$F2" ] && [ "$F2" = "$QSUM" ] && echo ⇒同一批字节 || echo '**不等⇒仪器有问题**' )"
# ★★★甲的"内容对不对"交给**结构尺**判(构建机现跑，与第 95 发同一枚二进制才可比)。
#   ★★上一版这里写的是 `staged_eq_live=1`＝**拿 md5 当语义证人**——那正是 11-03 立口径时禁掉的东西，
#   后果是把一次合法的往返判成"收了但判据不齐"(第 96 发我自己判红了自己)。md5 只答"两端是不是同一个件"。
AFV=""; AFBIN=""
if [ -s $EV/w1143_records_shot${SHOT}/pol.after ] && [ -s $EV/w1143_records_shot${SHOT}/img.bin ] && [ -s $EV/w1143_records_shot${SHOT}/pol.before ]; then
  RPUSH "$EV/w1143_records_shot${SHOT}/pol.after"   w${SHOT}_pol.after | sed 's/^/  put after: /'
  RPUSH "$EV/w1143_records_shot${SHOT}/img.bin"     w${SHOT}_pol.new   | sed 's/^/  put new  : /'
  RPUSH "$EV/w1143_records_shot${SHOT}/pol.before"  w${SHOT}_pol.orig  | sed 's/^/  put orig : /'
  RPUSH "$AF_RULER" w${SHOT}_after.sh | sed 's/^/  put ruler: /'
  AFV=$(REXEC "bash /home/lucy/w${SHOT}_after.sh /home/lucy/w1129_host w${SHOT}_pol.after w${SHOT}_pol.new w${SHOT}_pol.orig $IM $LIVE")
  echo "$AFV" | grep -aE '^(BIN_MD5|AF_|NEW_MD5_REMOTE|ORIG_MD5_REMOTE)' | sed 's/^/    /' | tee $EV/w1143_after_shot${SHOT}.txt
  AFBIN=$(echo "$AFV" | sed -n 's/^BIN_MD5=\([0-9a-f]*\).*/\1/p' | head -1)
  if [ "$AFBIN" = "$AF_BIN_MD5" ]; then echo "    尺子对表：装后件用的二进制＝$AFBIN ＝ 第 95 发那枚 ⇒ 两发的甲可比"; else echo "    [x] 尺子不是那枚($AFBIN) ⇒ 甲不许与 #95 并排比"; fi
else
  echo "    [!] after/img/before 不齐 ⇒ 甲的结构尺＝**未跑**，甲记未测(不许拿'没跑'当'过了')"
fi
AFOK=0
if [ -n "$AFV" ] && [ "$AFBIN" = "$AF_BIN_MD5" ]; then
  AFOK=1
  for k in "AF_VS_NEW_ADDED=0" "AF_VS_NEW_REMOVED=0" "AF_TMAP_VS_NEW_MISSING=0" "AF_TMAP_VS_NEW_EXTRA=0" "AF_TMAP_VS_VENDOR_MISSING=0" "AF_ZW=0" "AF_VERDICT=ok"; do
    grep -qF "$k" <<<"$AFV" || { echo "    [x] 甲缺 [$k]"; AFOK=0; }
  done
fi
JIA=0; [ "$WHY" = 0 ] && [ "$LRC" = 0 ] && [ "$QLEN" = "$ILEN" ] && [ -n "$F2" ] && [ "$F2" = "$QSUM" ] && [ "$AFOK" = 1 ] && JIA=1
YI=0
if [ "$KCP" = 0 ] && [ "$KCS" = 0 ] && [ "$RCP" != -1000 ] && [ "$RCS" != -1000 ]; then
  if [ "$MODE" = round ]; then [ "$RCP" = "$RCS" ] && YI=1; else [ "$RCP" != 0 ] && [ "$RCS" = 0 ] && YI=1; fi
fi
echo "    甲(structure)=$JIA (why=$WHY load_rc=$LRC post_len=$QLEN img_len=$ILEN 尺子=$AFBIN AFOK=$AFOK FNV两端 $F2/$QSUM ｜ 字节相等这格只当$EQS，不当语义证人)"
echo "    乙(behavior,MODE=$MODE)=$YI (test rc_pre=$RCP rc_post=$RCS ｜ ctrl 正对照 kc_pre=$KCP kc_post=$KCS sid $KSIDP→$KSIDS ｜ 声明的 policyvers=$WVERS)"
if   [ "$READY" != 1 ]; then V="未测(读法①：腿的两行没等到)"
elif [ -n "$WHY" ] && [ "$WHY" != 0 ]; then V="未测(读法②③④：闸/尺拦在装载之前 why=$WHY)"
elif [ "$LRC" != 0 ]; then V="判负(读法⑤：模块侧装载被内核拒 rc=$LRC)"
elif [ "$JIA" = 1 ] && [ "$YI" = 1 ]; then V="判正"
else V="收了但判据不齐(甲=$JIA 乙=$YI)"; fi
echo "  ★SHOT${SHOT}_B′=$V ｜ 武装面(全从 ARM 那一行取)：written=$ARMp want=$ARW live=$ARL armed_at_ARM=$ARD armed_after_GO=$ARD2 ｜ 装载前 len=$PLEN sum=$PSUM ｜ 交图 len=$ILEN sum=$ISUM"
echo "  ★这一发**没有**写 /sys/fs/selinux/load(走的是模块里的 security_load_policy)；口径：只答内核收不收／收的是不是我们那张图。"

echo "  收尾：reboot 回厂商策略并复核基线"
# ★★就绪闸不许用"输出非空"当证据：`A` 把 stderr 并进来，`adb: no devices` 也是非空 ⇒ 上一版这条闸
#   第一轮就"通过"了，于是"重启后"那行印的是 adb 的报错而不是设备的读数(＝例 230① 的另一个身位)。
adb reboot >/dev/null 2>&1; sleep 45
UP2=0
for i in $(seq 1 40); do
  ST=$(adb get-state 2>&1 | tr -d '\r' | tail -1)
  EN=$(A "getenforce" | tr -d '[:space:]')
  if [ "$ST" = device ] && { [ "$EN" = Enforcing ] || [ "$EN" = Permissive ]; }; then UP2=1; echo "  设备回来了(第 $i 轮，state=$ST getenforce=$EN)"; break; fi
  sleep 6
done
[ "$UP2" = 1 ] || echo "  [!!] 等满 40 轮设备仍未回到可读状态 ⇒ 这一格记**未测**，人工接管(别按第二下 reboot)"
BASE_POST='getenforce; echo KERNELSU=$(grep -c "^kernelsu " /proc/modules 2>/dev/null); echo Z6=$(grep -c "^z6polload " /proc/modules 2>/dev/null); echo BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null); echo W1142=$(ls -d /data/local/tmp/w1142 2>&1 | head -1)'
echo "    重启后：$(A "$BASE_POST" | tr '\n' ' ')"
A "rm -rf $DDEV" >/dev/null; echo "    撤场复证：$(A "ls -d $DDEV 2>&1")"
echo "CONSOLE 记：本件由 tee 生成 $CONSOLE"
