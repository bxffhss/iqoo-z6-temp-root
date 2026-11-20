#!/bin/bash
# w1130_shot95.sh —— 第 95 发＝#234：**运行期整图装载收不收"变长的 type 表"**（用户 11-03 明确点头这一格）。
#   问的只有一格：93/94 发已经把"运行期装载 + 我们序列化出来的 delta"判正了，但**那两发的 nprim 都没变**；
#   这一发把唯一变量换成"在类型表尾部插 2 个新类型(3645→3647)"。判据两条腿，缺一条就不算答：
#     甲＝**结构尺**：装完从 /sys/fs/selinux/policy 再导出的那份 pol.after（＝内核自己序列化出来的活策略），
#          在构建机上用 w1131 比三把——avtab 三元组 vs 我们推下去那份 0/0、ATAR 逐行 vs 我们那份 0/0、
#          厂商那 3645 行一行不少 ＋ 零削弱。只认结构尺，不拿 md5 当语义证人(11-03 立的口径)。
#     乙＝**行为尺**：往 /sys/fs/selinux/context 写那把新类型的名字——装载前必须解不开(rc≠0)、
#          装完厂商对照那份仍解不开、装完 delta 必须解开(rc=0)、翻回执法之后仍解开；
#          同时"瞎造的名字"全程解不开(负对照有牙)、"厂商就有的名字"全程解得开(正对照有牙)。
#          再加执法态同标签四格：read 通／write 红／exec 红／unlink 通(清理)，外加 exec 那格的**同形状正对照**
#          (老标签 shell_data_file 上的可执行件必须 rc=0)，否则"红"可能是"这台机压根不能 exec"。
#   ★派单顺序与 94 发不同(那儿是"只读导出腿→离线差分→装载腿")：本发把**导出＋导出面核对**搬进腿里
#     (§6.518 那一族的加强)：腿自己 `cat /sys/fs/selinux/policy`、自己把它与 expect.txt 里登记的厂商
#     md5/字节数对表，**对不上就地拒绝装载** ⇒ "装载面＝离线差分用过的那一份"这条闸发生在开枪的那一刻，
#     不是几分钟前。离线那一侧因此可以在开窗**之前**跑完(少占窗)。
#   ★读法(开枪前写死，六支，不许互相顶替)：
#     ①DRY_FAIL≠0 ⇒ 两次装载都没做 ⇒ **未测**，不许写"被拒"；
#     ②CTRL_rc=0 且 DELTA_rc≠0 ⇒ 装载机制通、**带新类型的这份图被内核拒**＝#234 判负(一手结论，看 errno 文字定位)；
#     ③CTRL_rc≠0 ⇒ 对照同错 ⇒ 墙在"运行期整图装载"这一层(与类型表无关)，#234 那一格记**未测**；
#     ④DELTA_rc=0 但 甲/乙 任一条不齐 ⇒ 记"收下了但没生效"，不许直接写"能装新类型"；
#     ⑤post_bogus=0(瞎造的名字也解得开了) ⇒ 那把尺没牙，乙这一侧全部作废；
#     ⑥pre_new=0(装载前就解得开) ⇒ 这台机上那把名字本来就活着，本发的对照面不成立 ⇒ 乙作废、甲仍算。
#   ★代价与恢复(量产机)：装载只在内存里、没有持久化；`adb reboot` 即回厂商策略(第 7 步必做并复核基线)。
#     这 1 条规则＋2 个新类型会在"翻回执法之后、重启之前"这几秒真生效，作用面只有 shell 域对
#     z6_probe_file:file 的 getattr/open/read/unlink；探针件全部落在腿自己建的 $P 里并在同一条腿里删净(带标签残留数
#     是证件里的一格)。**不进包、不作任何交付宣称**；目标③ 的真实缺口仍按 336 发＝厂商类型表里没有 `nsfs`。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT=${SHOT:-95}
RM_CLI=hermes-remote1/cli.py; RM_CFG=hermes-remote1/config.json
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
REXEC() { HRMT_CLI=$RM_CLI W682_T=300 PYTHONUTF8=1 python kmod/w682_rr.py "$1" 2>&1 | tr -d '\r'; }
RPUSH() { HRMT_CLI=$RM_CLI python $RM_CLI --config $RM_CFG put "$1" "$2" 2>&1 | tail -1; }
RGET()  { HRMT_CLI=$RM_CLI python $RM_CLI --config $RM_CFG get  "$1" "$2" 2>&1 | tail -1; }
if [ -n "${MSYS_NO_PATHCONV+set}" ]; then echo "[x] MSYS_NO_PATHCONV 被定义了(哪怕空值) ⇒ 拒跑(它会让离线自测假红；见例 218)"; exit 3; fi

LEGREPO=kmod/w1127_newtype_load_leg.sh; LEGDEV=/data/local/tmp/w1127_newtype_load_leg.sh
LEGOUT=/data/local/tmp/w1127_load.out;  DDEV=/data/local/tmp/w1127
CSRC=kmod/w1104_delta.c; RULES=kmod/sepolicy_delta/rules_newtype95.txt
RV=kmod/w1129_newtype_verify_remote.sh; RA=kmod/w1131_after_newtype_remote.sh
VENDOR=282a68611a2f36321a153fc0102f9ca0; VBYTES=1356948      # 一手＝89~94 发六次独立导出同值＋本轮离线量同一把
NEWTYPE=z6_probe_file
CONSOLE=$EV/w1130_shot${SHOT}_console.txt   # ★由调用方 `bash kmod/w1130_shot95.sh 2>&1 | tee <此件>` 生成；本件不自带 tee

echo "[1/7] 离线总闸(链内现跑)＋陈旧源码闸"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪(红的是闸就补前置，不是改闸)"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

SM=$(md5sum $CSRC | cut -d' ' -f1); LM=$(md5sum $LEGREPO | cut -d' ' -f1)
RLM=$(md5sum $RULES | cut -d' ' -f1); RVM=$(md5sum $RV | cut -d' ' -f1); RAM=$(md5sum $RA | cut -d' ' -f1)
echo "[2/7] 现值(不背历史)：源码 md5=$SM($(wc -l < $CSRC) 行) 腿 md5=$LM 规则 md5=$RLM 离线件 md5=$RVM 装后件 md5=$RAM"

echo "[3/7] ★离线造 pol.new＋七把闸(在构建机上跑，本步不碰设备；没全过就不开窗)"
#   ★底件＝链**自己现量**后再推上去的那一份(94 发从设备上导出、已证与厂商件逐字节相同)；
#     不依赖构建机工作目录里"大概还在"的陈件——那正是 91 发把跨 boot 旧产物当读数那一族的 PC 版。
VENDFILE=$EV/w1117_pol.orig_94
PM=$(md5sum $VENDFILE | cut -d' ' -f1); PB=$(wc -c < $VENDFILE)
echo "  底件现读：$VENDFILE = $PB B md5=$PM (期望 $VBYTES/$VENDOR)"
[ "$PM" = "$VENDOR" ] && [ "$PB" = "$VBYTES" ] || { echo "[x] 底件不是厂商那份 ⇒ 不开窗(离线闸的输入面就错了)"; exit 1; }
RPUSH "$CSRC"  w1130_src.c  | sed 's/^/  put src: /'
RPUSH "$RULES" w1130_rules.txt | sed 's/^/  put rl : /'
RPUSH "$RV"    w1130_verify.sh | sed 's/^/  put rv : /'
RPUSH "$VENDFILE" w1130_pol.orig | sed 's/^/  put pol: /'
OFF=$(REXEC "bash /home/lucy/w1130_verify.sh w1130_src.c $SM w1130_pol.orig w1130_rules.txt")
echo "$OFF" | grep -aE '^(SRC_MD5_LOCAL|BUILD|RULES_MD5|ORIG_MD5|ORIG_TYPES|RT_ADDED|TMAP_ORIG_ROWS|RULE_TYPE_LINES|INSERTED|NEW_MD5|TMAP_NEW_ROWS|TMAP_DRIFT|TMAP_PROBE_ROW|TMAP_UNUSED_ROW|C_ADDED|ZERO_WEAKEN|UNUSED_NODES|PROBE_NODES|RT2_ADDED|TMAP_RT2_SAME_ROWS|VERDICT)' | sed 's/^/    /' | tee $EV/w1130_offline_shot${SHOT}.txt
for k in "BUILD=ok" "SRC_MD5_LOCAL=$SM SRC_MD5_REMOTE=$SM" "RULES_MD5=$RLM" "ORIG_MD5=$VENDOR" \
         "RT_ADDED=0 RT_REMOVED=0" "TMAP_DRIFT=0" "ZERO_WEAKEN=0" "UNUSED_NODES=0" \
         "RT2_ADDED=0 RT2_REMOVED=0" "VERDICT=ok"; do
    grep -qF "$k" <<<"$OFF" || { echo "  [x] 离线闸缺 [$k] ⇒ **不开窗**"; exit 1; }
done
NEWM=$(echo "$OFF" | sed -n 's/^NEW_MD5=\([0-9a-f]*\).*/\1/p' | head -1)
BINM=$(echo "$OFF" | sed -n 's/.*BIN_MD5=\([0-9a-f]*\).*/\1/p' | head -1)
NEWB=$(echo "$OFF" | sed -n '/^NEW_MD5=/s/.*NEW_BYTES=\([0-9]*\).*/\1/p' | head -1)
NWT=$(echo "$OFF" | sed -n 's/.*NEW_TYPES=\([0-9]*\).*/\1/p' | head -1)
OT=$(echo "$OFF" | sed -n 's/^ORIG_TYPES=\([0-9]*\).*/\1/p' | head -1)
NTL=$(echo "$OFF" | sed -n 's/^RULE_TYPE_LINES=\([0-9]*\).*/\1/p' | head -1)
echo "  离线产物：new md5=$NEWM bytes=$NEWB 类型表 $OT→$NWT(规则里 type 行=$NTL)"
[ -n "$NEWM" ] && [ -n "$NEWB" ] || { echo "  [x] 没从离线输出里取到 new 的 md5/字节数 ⇒ 不开窗(空与 0 必须能分开，例 222)"; exit 1; }
[ "$NWT" = "$((OT + NTL))" ] || { echo "  [x] 类型表长出来的行数≠规则里的 type 行数 ⇒ 不开窗"; exit 1; }
RGET new.pol "$EV/w1130_pol.new_${SHOT}" >/dev/null
LM2=$(md5sum "$EV/w1130_pol.new_${SHOT}" | cut -d' ' -f1); LB2=$(wc -c < "$EV/w1130_pol.new_${SHOT}")
echo "  取回 pol.new 两端对表：本机=$LM2/$LB2 远端=$NEWM/$NEWB ⇒ $( [ "$LM2" = "$NEWM" ] && [ "$LB2" = "$NEWB" ] && echo 一致 || echo **不一致** )"
[ "$LM2" = "$NEWM" ] && [ "$LB2" = "$NEWB" ] || { echo "[x] pol.new 两端不一致 ⇒ 不开窗"; exit 1; }

echo "[4/7] 铺腿＋五把闸(x 位／plain s0／两端 md5／设备 mksh sh -n／乙那把尺的正负对照现量)"
MSYS_NO_PATHCONV=1 adb push $LEGREPO $LEGDEV 2>&1 | tail -1 | sed 's/^/  push leg: /'
A "mkdir -p $DDEV; chmod 755 $LEGDEV" >/dev/null
P=$(A "ls -l $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}'); LB=$(A "ls -Zd $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}')
DM=$(A "md5sum $LEGDEV 2>/dev/null" | cut -d' ' -f1)
S=$(MSYS_NO_PATHCONV=1 adb shell "/system/bin/sh -n $LEGDEV >/dev/null 2>&1 && echo SHN=OK || echo SHN=BAD" 2>&1 | tr -d '\r')
echo "  腿件 权限=$P 标签=$LB 设备md5=$DM 本机md5=$LM $S"
[ "${P:3:1}" = x ] || { echo "[x] 腿件没 x 位 ⇒ 不开窗"; exit 1; }
case "$LB" in *:s0) : ;; *) echo "[x] 腿件标签不是 plain s0 ⇒ 不开窗(#114)" ; exit 1 ;; esac
[ "$DM" = "$LM" ] || { echo "[x] 设备上不是本机这支腿(§6.155)⇒ 不开窗"; exit 1; }
grep -q SHN=OK <<<"$S" || { echo "[x] 腿没过设备语法闸 ⇒ 不开窗"; exit 1; }
#   ★乙那把尺(写 /sys/fs/selinux/context)在**开窗前**再认一次两端：正对照该 rc=0、被测与瞎造的名字该 rc≠0。
CAL=$(A 'cd /data/local/tmp; for c in u:object_r:system_data_file:s0 u:object_r:'"$NEWTYPE"':s0 u:object_r:z6_no_such_type95:s0; do printf "%s" "$c" > .c95.in; N=$(wc -c < .c95.in); dd if=.c95.in of=/sys/fs/selinux/context bs=$N count=1 >.c95.out 2>&1; echo "rc=$? [$c] $(head -c 60 .c95.out | tr "\n" "|")"; done; rm -f .c95.in .c95.out; echo 删后=[$(ls .c95.in 2>&1 | head -1)]')
echo "  ★ctx 尺基线现量(基线态、uid 2000、没开窗)："; echo "$CAL" | sed 's/^/      /'
grep -q 'rc=0 \[u:object_r:system_data_file' <<<"$CAL" || { echo "[x] ctx 尺的正对照在基线态就不通 ⇒ 那把尺没牙，先修尺再开窗"; exit 1; }
grep -q 'rc=[1-9] \[u:object_r:'"$NEWTYPE" <<<"$CAL" || { echo "[x] 被测类型名在**基线态**就解得开 ⇒ 本发的对照面不成立(读法⑥)，不开窗"; exit 1; }
grep -q 'rc=[1-9] \[u:object_r:z6_no_such_type95' <<<"$CAL" || { echo "[x] 负对照在基线态就通了 ⇒ 尺子坏了，不开窗"; exit 1; }
#   ★装载器形状的现量(94 发同款)：装载腿里那句 grep 的词必须在**这台设备这台 toybox**上现印得出来。
S2=$(A "cd /data/local/tmp; dd if=/dev/zero of=.w1130_z bs=$NEWB count=1 2>&1 | tr '\n' '|'; rm -f .w1130_z")
echo "  设备 dd 形状现测=$S2"
grep -q '1+0 records out' <<<"$S2" || { echo "[x] 设备 dd 没印『1+0 records out』⇒ 装载腿的形状闸词不对，先修词再开窗"; exit 1; }
#   ★铺 pol.new＋expect(四个登记值＋被测类型名)，并**删掉上一 boot 留下的同名腿件**再复证已删(91 发那一课)。
MSYS_NO_PATHCONV=1 adb push "$EV/w1130_pol.new_${SHOT}" $DDEV/pol.new 2>&1 | tail -1 | sed 's/^/  push pol.new: /'
A "printf 'MD5=%s\nBYTES=%s\nORIG_MD5=%s\nORIG_BYTES=%s\nNEWTYPE=%s\n' $NEWM $NEWB $VENDOR $VBYTES $NEWTYPE > $DDEV/expect.txt; chmod 666 $DDEV/pol.new $DDEV/expect.txt; cat $DDEV/expect.txt" | sed 's/^/  expect: /'
A "rm -f $LEGOUT" >/dev/null
GONE=$(A "ls -l $LEGOUT 2>&1"); echo "  派腿前复证：$GONE"
case "$GONE" in *"No such file"*) : ;; *) echo "[x] 腿件删不掉 ⇒ **不开窗**(派了也是拿陈件当读数)"; exit 1 ;; esac
BOOT0=$(A "cat /proc/sys/kernel/random/boot_id 2>&1"); echo "  本 boot 身份 boot_id(派前)=$BOOT0  up=$(A 'cut -d" " -f1 /proc/uptime')  enf=$(A 'cat /sys/fs/selinux/enforce')"

echo "[5/7] 开窗(1 枪＝punch)＋派**这一发唯一的那条腿**(导出→闸→干跑→装对照→装delta→导出→翻执法→行为格→清理)"
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LM" LEG1ONLY=1 I_KNOW=1 bash kmod/go.sh > $EV/w1130_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1130_shot${SHOT}_go.log | sed 's/^/  go: /'
ROUND=0; READY=0
for i in $(seq 1 100); do ROUND=$i
    B=$(A "grep -acF 'BEGIN v95' $LEGOUT 2>/dev/null" | tr -dc '0-9')
    E=$(A "grep -acF 'END up=' $LEGOUT 2>/dev/null" | tr -dc '0-9')
    if [ "${B:-0}" -ge 1 ] && [ "${E:-0}" -ge 1 ]; then READY=1; echo "  腿跑完(第 $i 轮：新件里 BEGIN v95 与 END 齐)"; break; fi
    if [ "${B:-0}" = 0 ] && [ "${E:-0}" -ge 1 ]; then echo "  [!] 第 $i 轮：件里有 END 却没有 BEGIN v95 ⇒ **陈件**，继续等真这一份"; fi
    sleep 3
done
[ "$READY" = 1 ] || echo "  [!] 等满 $ROUND 轮没等到新件两行 ⇒ 这一格记**未测**(『没输出』既不当通过也不当被拒)"
A "cat $LEGOUT 2>/dev/null" > $EV/w1130_leg_shot${SHOT}.out 2>&1
BOOT1=$(A "cat /proc/sys/kernel/random/boot_id 2>&1")
LB2b=$(sed -n 's/^LEG_BOOTID=\[\(.*\)\].*/\1/p' $EV/w1130_leg_shot${SHOT}.out 2>/dev/null | head -1)
#   ★身份比的**一对**要选对：go.sh 第 2 步本来就要 `adb reboot` 再 punch ⇒ "派 go.sh 之前读的那份"必然与腿的不同，
#     拿它当第三方等式的一边就是我自己的仪器洞(第 95 发的证件里就是这么误判了一次"未测")。
#     该比的是【腿自印 LEG_BOOTID ＝ go.sh 返回后读回的这份】(证明这条腿跑在我们正在读的这扇窗里)，
#     另外顺手记一条"派前≠派后"＝go.sh 确实重启过(它若没重启，本发的"1 boot 1 枪"就要重看)。
echo "  ★boot 身份：派 go.sh 前=$BOOT0 go.sh 返回后=$BOOT1 腿自印=$LB2b"
echo "  ★判①腿在这扇窗里跑过：$( [ -n "$LB2b" ] && [ "$BOOT1" = "$LB2b" ] && echo '相等＝成立' || echo '**不相等⇒这一格未测**' )"
echo "  ★判②go.sh 确实换过 boot(它第 2 步 reboot)：$( [ "$BOOT0" != "$BOOT1" ] && echo '是(派前≠派后)' || echo '[!] 相等⇒go.sh 没重启，本发形状要重看' )"
MSYS_NO_PATHCONV=1 adb pull $DDEV $EV/w1130_records_shot${SHOT} 2>&1 | tail -1 | sed 's/^/  pull: /'
grep -aE 'BEGIN v95|LEG_BOOTID|ARM=|NEW_md5|ORIG_export_rc|P_DIR|PRE_|DRY_|★CTRL_LOAD|★DELTA_LOAD|AFTER_|ENFORCE_flip|★POST_|★EXECOLD|CTRL_|CLEAN_|COUNTS|K95|END up=|\[x\]' $EV/w1130_leg_shot${SHOT}.out | cut -c1-250 | sed 's/^/    /'

echo "[6/7] ★判读：甲(结构尺，构建机上比 pol.after)＋乙(行为尺，腿里那 12 个 rc)"
K=$(sed -n '/^K95 /p' $EV/w1130_leg_shot${SHOT}.out 2>/dev/null | head -1)
echo "  K95 原行=[$K]"
g() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$K" | head -1; }
LOADRC=$(g load_rc); CTRLRC=$(g ctrl_rc); DRYF=$(g dry_fail)
PREn=$(g pre_new); PREg=$(g pre_good); PREb=$(g pre_bogus)
CTn=$(g ct_new); CTg=$(g ct_good)
POSTn=$(g post_new); POSTb=$(g post_bogus); POSTg=$(g post_good)
E2n=$(g enf_new); E2b=$(g enf_bogus)
LBL=$(g label_ok); RD=$(g read_rc); WR=$(g write_rc); EX=$(g exec_rc); EO=$(g execold_rc)
GA=$(g getattr_rc); CA=$(g chcon_after_rc); S0=$(g setenf0_rc); RES=$(g residue_labelled)
EMPTY=0; for v in LOADRC CTRLRC DRYF PREn PREg PREb CTn POSTn POSTb E2n E2b LBL RD WR EX EO GA CA S0 RES; do
    [ -n "${!v}" ] || { echo "    [x] 取数取到空串($v) ⇒ 例 222 那一族，这一侧按未测处理"; EMPTY=1; }
done
echo "    乙：装前 被测=$PREn 正=$PREg 负=$PREb ｜装完厂商对照 被测=$CTn ｜装完 delta 被测=$POSTn 负=$POSTb 正=$POSTg ｜执法后 被测=$E2n 负=$E2b"
echo "    乙：标签落地=$LBL read=$RD write=$WR exec=$EX exec老标签正对照=$EO getattr=$GA 执法后再chcon=$CA setenforce0=$S0 带标签残留=$RES"
CTXLIVE=0; [ -n "$PREn$POSTn$E2n$POSTb$E2b$PREg" ] && [ "$PREn" != 0 ] && [ "$POSTn" = 0 ] && [ "$E2n" = 0 ] && [ "$POSTb" != 0 ] && [ "$E2b" != 0 ] && [ "$PREg" = 0 ] && CTXLIVE=1
[ "$PREn" = 0 ] && echo "    [!] 读法⑥：被测名字在**装载前**就解得开 ⇒ 乙这一侧对照面不成立(甲仍算)"
BEHAV=0; [ -n "$LBL$RD$WR$EX$EO$GA$S0$RES" ] && [ "$LBL" = 1 ] && [ "$RD" = 0 ] && [ "$GA" = 0 ] && [ "$WR" != 0 ] && [ "$EX" != 0 ] && [ "$EO" = 0 ] && [ "$S0" != 0 ] && [ "$RES" = 0 ] && BEHAV=1
if   [ -n "$DRYF" ] && [ "$DRYF" != 0 ]; then V95="未装载(形状闸红)"
elif [ "$CTRLRC" != 0 ]; then V95="未测(对照与delta同层，装载路径这一发没通)"
elif [ "$LOADRC" != 0 ]; then V95="内容被拒(对照0/delta非0)"
elif [ "$CTXLIVE" = 1 ] && [ "$BEHAV" = 1 ]; then V95=判正
else V95="收下了但判据不齐(EMPTY=$EMPTY)"; fi
echo "  ★SHOT95_乙(行为尺) CTXLIVE=$CTXLIVE BEHAV=$BEHAV EMPTY=$EMPTY ⇒ 读法见文件头"
if [ -f $EV/w1130_records_shot${SHOT}/pol.after ]; then
    RPUSH "$EV/w1130_records_shot${SHOT}/pol.after" w1130_pol.after | sed 's/^/  put after: /'
    RPUSH "$EV/w1130_pol.new_${SHOT}"              w1130_pol.new   | sed 's/^/  put new  : /'
    LIVE=$(md5sum "$EV/w1130_records_shot${SHOT}/pol.orig" 2>/dev/null | cut -d' ' -f1)
    echo "  设备上那条腿自己导出的那份：md5=$LIVE ⇒ 与厂商件$( [ "$LIVE" = "$VENDOR" ] && echo 相同 || echo '**不同**(腿里那道闸本该拦住它，两处读数对不上就是仪器问题)' )"
    RPUSH "$EV/w1130_records_shot${SHOT}/pol.orig" w1130_live.orig | sed 's/^/  put orig : /'
    RPUSH "$RA" w1130_after.sh | sed 's/^/  put ra   : /'
    AFV=$(REXEC "bash /home/lucy/w1130_after.sh /home/lucy/w1129_host w1130_pol.after w1130_pol.new w1130_live.orig $NEWM $VENDOR")
    echo "$AFV" | grep -aE '^(BIN_MD5|AF_|NEW_MD5_REMOTE|ORIG_MD5_REMOTE)' | sed 's/^/    /' | tee -a $EV/w1130_offline_shot${SHOT}.txt
    echo "$AFV" | grep -aE '^  (ADDVSNEW|DELVSNEW|GONE|ADDED|GONEVENDOR|AF_WEAKEN)' | sed 's/^/    /'
    AFBIN=$(echo "$AFV" | sed -n 's/^BIN_MD5=\([0-9a-f]*\).*/\1/p' | head -1)
    [ -n "$BINM" ] && [ "$AFBIN" = "$BINM" ] && echo "    同一把尺对表：装后件用的二进制 md5=$AFBIN 与离线那一步编出来的 相同" || echo "    [x] 装后件用的二进制与离线那一步的不是同一件($AFBIN vs $BINM) ⇒ 甲这一侧不算数"
    #   ★取数不许锚行首：w1131 把 AF_MD5/AF_BYTES/AF_TYPES/AF_NODES 印在**同一行**(例 222 那一族，这次犯在我自己链上)
    AFT=$(echo "$AFV" | sed -n 's/.*AF_TYPES=\([0-9]*\).*/\1/p' | head -1)
    echo "    甲那一行原样=[$(echo "$AFV" | grep -a '^AF_MD5=' | head -1)]"
    structok=0
    for k in "AF_VS_NEW_ADDED=0" "AF_VS_NEW_REMOVED=0" "AF_TMAP_VS_NEW_MISSING=0" "AF_TMAP_VS_NEW_EXTRA=0" "AF_TMAP_VS_VENDOR_MISSING=0" "AF_ZW=0" "AF_VERDICT=ok"; do
        grep -qF "$k" <<<"$AFV" || { echo "    [x] 甲缺 [$k]"; structok=1; }
    done
    [ "$AFT" = "$NWT" ] || { echo "    [!] 甲：pol.after 的类型表数=$AFT 与 new.pol 的=$NWT 不等"; structok=1; }
    echo "  ★SHOT95_甲(结构尺) struct_missing=$structok types_after=$AFT (厂商=$OT)"
    [ "$V95" = 判正 ] && [ "$structok" != 0 ] && V95=收下了但甲不齐
else
    echo "  [!] pol.after 不在(没导出) ⇒ 甲这一侧＝未导出，不许拿'0 差'当结论(93 发那一课的假账)"
    [ "$V95" = 判正 ] && V95=收下了但甲没导出
fi
echo "  ★SHOT95_VERDICT=$V95"

echo "[7/7] 关窗（★重启＝把机器收回厂商策略；这次装载只在内存里，没持久化）＋残留复核"
A "svc power stayon false" >/dev/null
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") boot_id=$(A "cat /proc/sys/kernel/random/boot_id")"
#   ★重启后由链(uid 2000＝$D 的属主)把这一发的落点删净($P 是 root 家的空壳目录，腿在执法态删不掉它——
#     删它需要 CAP_DAC_OVERRIDE，而本发故意没给；这里用 shell 自己的属主身份删，不动策略)。
A "rm -rf $DDEV $LEGDEV /data/local/tmp/w1127_newtype_load_leg.sh" >/dev/null
RESDIR=$(A "ls -d $DDEV $LEGDEV 2>&1 | tr '\n' '|'")
echo "  残留复核(删后现读)=[$RESDIR]  标签面=$(A "ls -Z /data/local/tmp 2>&1 | grep -ac z6_probe_file") 条带 $NEWTYPE 标签的件"
echo "SHOT${SHOT}_DONE verdict=$V95 证件：$CONSOLE $EV/w1130_shot${SHOT}_go.log $EV/w1130_leg_shot${SHOT}.out $EV/w1130_offline_shot${SHOT}.txt $EV/w1130_pol.new_${SHOT} $EV/w1130_records_shot${SHOT}/"
