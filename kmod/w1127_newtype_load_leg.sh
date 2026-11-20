#!/system/bin/sh
# w1127_newtype_load_leg.sh —— 第 95 发(#234)的装载腿：**运行期整图装载收不收"变长的 type 表"**。
#   形状照 w1108 v3(第 93 发已用正例证明这套形状在这台机上跑得通)：
#     · 一次 write() 交整份 ⇒ `dd bs=<整份字节数> count=1`，且**先对普通文件干跑**证形状；
#     · 同窗 A/B 对照 ⇒ 先把设备上刚导出、逐字节就是厂商当前生效那份的 pol.orig 装一次(语义空操作)；
#       它 rc=0 而 delta 红 ⇒ 墙在"内容"；两条同错 ⇒ 墙在"运行期整图装载"这一层，delta 那格仍算未测；
#     · md5/字节数与链的登记不符就地拒绝装载(装载面必须＝被离线差分验过的那一份)；
#     · pol.after **无论成败都导出**(成败都要有"策略有没有被动过"的独立证人)。
#   ★与 w1108 的三处不同(都由这一发的问题决定，不是顺手改)：
#     ①**装前/装后的类型证人换成 `/sys/fs/selinux/context`**。93/94 发那条 `AVCN()` 靠 dmesg 数 avc denied，
#       而执法后 dmesg 要 CAP_SYSLOG(§6.452 实测红)⇒ 拿它当判据会在该出读数的地方出"空"。
#       11-03 0 枪在这台机上把新尺的两端都量过(同一个 toybox dd)：
#         写 `u:object_r:system_data_file:s0` ⇒ `1+0 records out` rc=0；
#         写 `u:object_r:z6_no_such_type:s0`  ⇒ `write error: Invalid argument`＋`0+0 records out`；
#         写垃圾形状 `u:invalid_shape`        ⇒ 同样拒 ⇒ 它答的就是"这个名字在这份活策略里解不解得开"。
#       ★★同一条量法顺手排掉一个假绿：toybox 的 `echo` **不检查 write 的返回码**(0 枪实测三种输入全 rc=0)
#         ⇒ 这一格必须用 dd，不许用 `echo >` 顶(例 219：拒人的闸要先跑"合法输入必须过"的正对照)。
#     ②新增"标签落地"那一格：Permissive 段 chcon 到 z6_probe_file ＋ `ls -Z` 读回——
#       ★第 95 发一手把这格的**能证什么**收窄了：chcon 的 rc 与读回的字符串**都不是**"类型存不存在"的证人。
#         uid 0 带 CAP_MAC_ADMIN ⇒ 5.4.281 hooks.c 在 `security_context_to_sid` 返 -EINVAL 后走
#         `..._to_sid_force` 那条支，于是装载**之前** chcon 也 rc=0，而 `ls -Z` 读的是**文件系统 xattr 里那串字节**
#         (不是内核 SID 的规范串)⇒ 它只证明"串写进去了"。真正"解不解得开"的证人只有 ①那把尺；
#         这一格与执法态那几格合起来才说明"这个标签被决策路径认了"(read 通／write·exec 红)。
#     ③执法态那几格换成"同一把新标签上 给了/没给 的对"：read 通、write 红、exec 红、unlink 通，
#       并且 exec 那一格带**同形状正对照**(老标签 shell_data_file 上的可执行件必须 rc=0)⇒
#       "新标签上红"才是 MAC 的事，不是"这台机压根不能 exec"。
#       ★跑 exec 用**直接调用**(`$P/z95_exec`)不是 `sh $P/z95_exec`：后者是 mksh 去 open 那个脚本，
#         量的其实是 read(而我们恰好给了 read)⇒ 会绿，是个没有判别力的假对照(#227/#228 那一族)。
#   ★这一份 delta 里没有任何 capability 行 ⇒ 所有需要写面的动作都排在翻执法**之前**做完；
#     翻转后只碰"$P 里腿自己(uid 0)家的件"。$P 铺成 0777 是有意的：
#     执法态下 uid 0 删得掉自己打的标签(＝unlink 那一格的证人)，而**空目录 $P 留给链在 reboot 后由 shell(uid 2000＝$D 的属主)删**，
#     因为 rmdir $P 要对 $D(shell 家,0700)有写＝要 CAP_DAC_OVERRIDE，而本发故意没给那条 ⇒ 不为了收尾去放宽自己。
#   ★一条规则：一个文件只有一个写者(§6.461)。本件 $L 只有本腿写。
L=/data/local/tmp/w1127_load.out
D=/data/local/tmp/w1127
P=$D/p
NEW=$D/pol.new; ORIG=$D/pol.orig; EXPECT=$D/expect.txt; POLA=$D/pol.after
CTXT=z6_probe_file                    # 被测的那把新类型(链把名字也登记进 expect.txt)
BOGUS=z6_no_such_type95               # 永远不该解得开的那把(负对照)
GOOD=u:object_r:system_data_file:s0   # 厂商就有、永远该解得开的那把(正对照)
: > $L
UP() { cut -d' ' -f1 /proc/uptime; }
say() { echo "$*" >> $L; }
# 一条 dd：★stdout 与 stderr **合进同一份文件**($4)，返回码进全局 RC(93 发的教训：toybox dd 把
#   `1+0 records out` 打在 stderr，闸只查 stdout 那份会把自己的合法输入拒了)。
onedd() { dd if=$1 of=$2 bs=$3 count=1 >$4 2>&1; RC=$?; }
errtxt() { head -c 140 $1 2>&1 | tr '\n' '|'; }
# ★类型解析尺：把上下文串当**一整条记录**写进 /sys/fs/selinux/context；RC 由调用方**当场另存**
#   (一个词只有一个意思：ctxprobe 不替调用方起名，避免 93 发那种"一词两义"的假读数)
#   ★临时件必须落在 $P(root 家)而不是 $D(shell 家)：翻执法后 uid 0 在 $D 里新建任何件都要
#     CAP_DAC_OVERRIDE，而本发故意没给 capability ⇒ 落错地方的话 POST2 那两格会因为 **DAC** 而红，
#     那个红回答不了"这个名字解不解得开"(#227/#228 那一族：没有判别力的读数)。
ctxprobe() {
    printf '%s' "$2" > $P/ctx_in_$1
    CL=$(wc -c < $P/ctx_in_$1 2>/dev/null)
    onedd $P/ctx_in_$1 /sys/fs/selinux/context "$CL" $P/ctx_out_$1
    say "$1 rc=$RC bytes=$CL 串=[$2] dd自报与errno=[$(errtxt $P/ctx_out_$1)] up=$(UP)"
}

say "BEGIN v95 up=$(UP) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)"
say "LEG_BOOTID=[$(cat /proc/sys/kernel/random/boot_id 2>&1)] LEG_UP_AT_BEGIN=$(UP)"
say "ARM=装载带新类型的 pol.new(整份一次 write 进 /sys/fs/selinux/load)→装前先装 pol.orig 当对照→再导出→翻执法→read/write/exec/unlink 四格"
# --- 1) 装载前四把硬闸：件在、大小=登记、md5=登记、**自己当场导出的那份也=登记** ---
if [ ! -f $NEW ]; then say "[x] 设备上没铺 pol.new ⇒ 不装载"; chmod 666 $L; echo "END up=$(UP) verdict=未装载" >> $L; exit 0; fi
NM=$(md5sum $NEW 2>/dev/null | cut -d' ' -f1); NS=$(wc -c < $NEW 2>/dev/null)
EM=$(sed -n 's/^MD5=//p' $EXPECT 2>/dev/null); ES=$(sed -n 's/^BYTES=//p' $EXPECT 2>/dev/null)
EOM=$(sed -n 's/^ORIG_MD5=//p' $EXPECT 2>/dev/null); EOS=$(sed -n 's/^ORIG_BYTES=//p' $EXPECT 2>/dev/null)
ECT=$(sed -n 's/^NEWTYPE=//p' $EXPECT 2>/dev/null)
say "NEW_md5=$NM bytes=$NS  登记 md5=$EM bytes=$ES 登记新类型=[$ECT]"
if [ "$NM" != "$EM" ] || [ "$NS" != "$ES" ]; then
    say "[x] 设备上那份 pol.new 与链的登记不符 ⇒ **拒绝装载**(装载面必须＝被离线差分验过的那一份)"
    chmod 666 $L; echo "END up=$(UP) verdict=未装载" >> $L; exit 0
fi
#   ★对照面必须**当场**导出并与登记的厂商件逐字节对上；对不上就不装(装了也不知道装的是哪一份)。
cat /sys/fs/selinux/policy > $ORIG 2>$D/export.err
EXP1=$?
OS=$(wc -c < $ORIG 2>/dev/null); OM=$(md5sum $ORIG 2>/dev/null | cut -d' ' -f1)
say "ORIG_export_rc=$EXP1 md5=$OM bytes=$OS (登记=$EOM/$EOS) err=[$(head -1 $D/export.err 2>&1 | cut -c1-110)]"
if [ "$OM" != "$EOM" ] || [ "$OS" != "$EOS" ]; then
    say "[x] 设备上刚导出的那份**不是**离线差分用过的那份 ⇒ **拒绝装载**"
    chmod 666 $L; echo "END up=$(UP) verdict=未装载" >> $L; exit 0
fi
mkdir -p $P 2>/dev/null; chmod 777 $P 2>/dev/null
say "P_DIR=[$(ls -ld $P 2>&1 | cut -c1-70)]"
# --- 2) 装前的类型解析尺(三把一起：正对照＋负对照＋被测) ---
ctxprobe PRE_bogus "u:object_r:$BOGUS:s0"; PREb=$RC
ctxprobe PRE_good "$GOOD";                 PREg=$RC
ctxprobe PRE_new "u:object_r:$CTXT:s0";    PREn=$RC
# --- 3) 装前的"标签落地"那一格(**丢弃件**，当场删)：只看 rc 不算数，见文件头② ---
touch $P/pre_throw 2>>$L
chcon u:object_r:$CTXT:s0 $P/pre_throw 2>>$L
say "PRE_chcon_rc=$? 读回标签=[$(ls -Zd $P/pre_throw 2>&1 | cut -d' ' -f1)] (期望解不开⇒rc≠0 或标签不是 $CTXT)"
rm -f $P/pre_throw 2>/dev/null; say "PRE_throw_残留=[$(ls $P/pre_throw 2>&1 | cut -c1-50)]"
say "PRE_SYSERVER=[$(pidof system_server 2>&1 | tr -s ' ' | cut -c1-30)]"
sync
# --- 4) ★形状闸：先对普通文件干跑，证"一次交整份"在这台机上成立，才允许碰 load ---
DRYBAD=0
for spec in "ORIG|$OS|$D/dry_orig.bin" "NEW|$NS|$D/dry_new.bin"; do
    TAG=$(echo "$spec" | cut -d'|' -f1); B=$(echo "$spec" | cut -d'|' -f2); T=$(echo "$spec" | cut -d'|' -f3)
    SRC=$ORIG; [ "$TAG" = NEW ] && SRC=$NEW
    if [ -z "$B" ] || [ "$B" -le 0 ]; then say "DRY_$TAG=跳过(没拿到字节数)"; DRYBAD=1; continue; fi
    onedd "$SRC" "$T" "$B" $D/dry_$TAG.out
    say "DRY_$TAG rc=$RC bs=$B dd自报=[$(errtxt $D/dry_$TAG.out)] 落点字节=$(wc -c < $T 2>/dev/null) 落点md5=$(md5sum $T 2>/dev/null | cut -d' ' -f1) 源md5=$(md5sum $SRC 2>/dev/null | cut -d' ' -f1)"
    [ "$RC" = 0 ] || { say "[x] DRY_$TAG dd 本身没跑通 ⇒ 不许去碰 load"; DRYBAD=1; }
    grep -qa '1+0 records out' $D/dry_$TAG.out 2>/dev/null || { say "[x] DRY_$TAG 没记到『1+0 records out』⇒ 它不是一次写完，形状不成立"; DRYBAD=1; }
    #   ★光比 md5 抓不住短读(11-02 现场量过：源截短后落点 md5 仍与那份短源相同)⇒ 必须同时要求落点字节数＝整份。
    [ "$(wc -c < $T 2>/dev/null)" = "$B" ] || { say "[x] DRY_$TAG 落点字节≠$B ⇒ 交出去的不是整份"; DRYBAD=1; }
    [ "$(md5sum $T 2>/dev/null | cut -d' ' -f1)" = "$(md5sum $SRC 2>/dev/null | cut -d' ' -f1)" ] || { say "[x] DRY_$TAG 落点内容与源不同 ⇒ 形状不成立"; DRYBAD=1; }
done
DRY=$DRYBAD
say "DRY_SHAPE_OK=$([ "$DRY" = 0 ] && echo 1 || echo 0) (★这条不成立，下面两次装载都不做)"
# --- 5) 装载（对照在前、delta 在后）；★读数看 errno 的文字，不许拿 rc 当 errno ---
CLOAD=0; CLOADRC=-1; LOADRC=-1; CTn=-1; CTg=-1
if [ "$DRY" = 0 ]; then
    onedd "$ORIG" /sys/fs/selinux/load "$OS" $D/load_ctrl.out
    CLOADRC=$RC; CLOAD=1
    say "★CTRL_LOAD_rc=$CLOADRC bs=$OS dd自报与errno=[$(errtxt $D/load_ctrl.out)] up=$(UP) enf_now=$(cat /sys/fs/selinux/enforce 2>&1) syserver=[$(pidof system_server 2>&1 | tr -s ' ' | cut -c1-30)]"
    #   对照装完立刻复量解析尺：新类型**仍该**解不开(装的还是同一份厂商图，语义空操作)
    ctxprobe CT_orig_new "u:object_r:$CTXT:s0"; CTn=$RC
    ctxprobe CT_orig_good "$GOOD"; CTg=$RC
    onedd "$NEW" /sys/fs/selinux/load "$NS" $D/load_delta.out
    LOADRC=$RC
    say "★DELTA_LOAD_rc=$LOADRC bs=$NS dd自报与errno=[$(errtxt $D/load_delta.out)] up=$(UP) enf_now=$(cat /sys/fs/selinux/enforce 2>&1) syserver=[$(pidof system_server 2>&1 | tr -s ' ' | cut -c1-30)]"
    if [ "$LOADRC" != 0 ]; then
        say "[x] delta 这一次整图写被内核拒(errno 见上面的文字)⇒ 策略没换成 delta；这不是『成功但没生效』，也要等对照那一条读完才谈归因"
    fi
else
    say "[x] 形状闸没过 ⇒ 两次装载都**没做**，这一格按未测收，不许写『被拒』"
fi
# --- 6) ★装后的类型解析尺(这三行就是 #234 的答案)：被测该解开，瞎造的名字仍不该解开 ---
ctxprobe POST_new "u:object_r:$CTXT:s0";   POSTn=$RC
ctxprobe POST_bogus "u:object_r:$BOGUS:s0"; POSTb=$RC
ctxprobe POST_good "$GOOD";                POSTg=$RC
# --- 7) 打标签(Permissive 段；两把探针＋一把老标签的正对照件) ---
echo hi > $P/z95_probe 2>>$L
printf '#!/system/bin/sh\necho SHOULD_NOT_RUN\n' > $P/z95_exec 2>>$L
printf '#!/system/bin/sh\necho OLDLABEL_RAN\n' > $P/z95_execold 2>>$L
chmod 777 $P/z95_probe $P/z95_exec $P/z95_execold 2>>$L
chcon u:object_r:$CTXT:s0 $P/z95_probe 2>>$L; CH1=$?
chcon u:object_r:$CTXT:s0 $P/z95_exec 2>>$L; CH2=$?
LBL1=$(ls -Zd $P/z95_probe 2>&1 | cut -d' ' -f1); LBL2=$(ls -Zd $P/z95_exec 2>&1 | cut -d' ' -f1)
LBLOK=0; [ "$LBL1" = "u:object_r:$CTXT:s0" ] && [ "$LBL2" = "u:object_r:$CTXT:s0" ] && LBLOK=1
say "★POST_chcon_rc=$CH1/$CH2 读回标签=[$LBL1|$LBL2] 两把都是$CTXT=$LBLOK (★证人是**读回的字符串**，不是 chcon 的 rc，见文件头②)"
# --- 8) 再导出（成败都做：装载失败也要有"策略没变"的独立证人）---
cat /sys/fs/selinux/policy > $POLA 2>$D/after.err
EXP2=$?
AFMD5=$(md5sum $POLA 2>/dev/null | cut -d' ' -f1); AFBY=$(wc -c < $POLA 2>/dev/null)
say "AFTER_export_rc=$EXP2 bytes=$AFBY md5=$AFMD5 orig_md5=$OM"
say "AFTER_HEAD16=$(od -An -tx1 -N16 $POLA 2>&1 | tr -s ' ')"
#   ★翻执法前把件读完：翻转后 uid 0 在 shell 家的 $D 里再动任何件都要 CAP_DAC_OVERRIDE，
#     而这一份 delta **故意没给** capability ⇒ 该拿的数必须在还能拿的时候拿完。
chmod a+r $POLA 2>/dev/null; chmod -R a+r $D 2>/dev/null
# --- 9) 翻回执法（**单向**：§6.441 写不回 0）---
echo 1 > /sys/fs/selinux/enforce 2>>$L
say "ENFORCE_flip_rc=$? enf_now=$(cat /sys/fs/selinux/enforce 2>&1) up=$(UP)"
# --- 10) 执法态行为格：同一把新标签上"给了的通、没给的红"＋同形状正对照 ---
cat $P/z95_probe >$P/read.out 2>$P/read.err; RD=$?
say "★POST_read_rc=$RD 内容=[$(head -c 12 $P/read.out 2>&1 | tr '\n' '|')] err=[$(head -1 $P/read.err 2>&1 | cut -c1-110)] (该翻绿：delta 给了 open/read)"
echo more 2>$P/write.err >> $P/z95_probe; WR=$?   # ★顺序不能反：mksh 在 `>>` 打开失败时就不再应用后面的 `2>`，反了会丢掉理由文字(第 95 发实测)
say "★POST_write_rc=$WR err=[$(head -1 $P/write.err 2>&1 | cut -c1-110)] (该红：delta 没给 write)"
$P/z95_exec >$P/exec.out 2>$P/exec.err; EX=$?
say "★POST_exec_rc=$EX 输出=[$(head -c 40 $P/exec.out 2>&1)] err=[$(head -1 $P/exec.err 2>&1 | cut -c1-110)] (该红：delta 没给 execute)"
$P/z95_execold >$P/execold.out 2>$P/execold.err; EO=$?
say "★EXECOLD_ctrl_rc=$EO 输出=[$(head -c 40 $P/execold.out 2>&1)] err=[$(head -1 $P/execold.err 2>&1 | cut -c1-110)] (★正对照：老标签 shell_data_file 上厂商本来就给 execute/execute_no_trans ⇒ 该 0；它若红，上一条的『红』就不是 MAC 的事)"
ls -Zd $P/z95_probe >$P/lsz.txt 2>&1; GA=$?
say "★POST_getattr_rc=$GA 标签还在=[$(cut -d' ' -f1 $P/lsz.txt 2>&1)] (该通：delta 给了 getattr)"
chcon u:object_r:$CTXT:s0 $P/z95_probe 2>$P/chcon2.err; CA=$?
say "CTRL_chcon_after_rc=$CA err=[$(head -1 $P/chcon2.err 2>&1 | cut -c1-110)] (该红：没给 mac_admin 也没给 file:write；写成同一个标签⇒即便通了标签也不会被改掉)"
ctxprobe POST2_new "u:object_r:$CTXT:s0";   P2n=$RC
ctxprobe POST2_bogus "u:object_r:$BOGUS:s0"; P2b=$RC
#   负对照：我们**没有**给 capability2{mac_override/mac_admin} ⇒ 执法态下把 enforce 写回 0 必须仍被拒。
echo 0 > /sys/fs/selinux/enforce 2>$P/enf0.err; S0=$?
say "CTRL_setenforce0_rc=$S0 enf_after_ctrl=$(cat /sys/fs/selinux/enforce 2>&1) err=[$(head -1 $P/enf0.err 2>&1 | cut -c1-110)] (期望 rc≠0 且仍=1；若真变 0 ⇒ 我们放得太宽，红)"
# --- 11) 清理（unlink 正是 delta 给的那条 ⇒ 这一格同时也是"给了的权限真能用"的证人）---
rm -f $P/z95_probe $P/z95_exec $P/z95_execold 2>$P/rm.err; RMRC=$?
#   ★残留按**标签**数而不是按文件数：$P 里本来就还留着 ctx 尺的临时件(它们是该留的证人)，
#     要证的只有一件事——没有任何件带着 $CTXT 这把标签活过这一发。
RES=$(ls -Z $P 2>&1 | grep -ac "$CTXT")
say "CLEAN_rm_rc=$RMRC 带$CTXT标签的残留件=$RES 列表=[$(ls -Z $P 2>&1 | tr '\n' '|' | cut -c1-120)] err=[$(head -1 $P/rm.err 2>&1 | cut -c1-110)]"
rm -f $D/dry_orig.bin $D/dry_new.bin 2>/dev/null
#   ★$P 里的执法后读数件是 uid 0 以 0600 建的，链那边是 uid 2000 ⇒ 不 a+r 就 pull 不回来(读数虽然都并进 $L 了，
#     但原始 stdout/stderr 文件是证件的一部分)； setattr 这些件我们自己就是属主，执法态下也做得动。
chmod -R a+r $P 2>/dev/null
chmod 666 $L 2>/dev/null
sync
V=装载失败
[ "$LOADRC" = 0 ] && V=delta已装载
[ "$DRY" != 0 ] && V="未装载(形状闸红)"
#   ★93 发那一课：一个词只许有一个意思——计数走 DRY_FAIL，布尔只由 DRY_SHAPE_OK= 那行负责。
say "COUNTS CTRL_LOADED=$CLOAD CTRL_rc=$CLOADRC DELTA_rc=$LOADRC DRY_FAIL=$DRY AF_MD5=$AFMD5 AF_BYTES=$AFBY"
#   ★机读行(链只认这一行；读法：`*_new`/`*_bogus`/`*_good`＝往 /sys/fs/selinux/context 写那个名字的 rc，
#     **0＝这个名字在这份活策略里解得开**，非 0＝解不开；pre_*=装载前 ct_*=装完厂商那份对照之后
#     post_*=装完 delta 之后 enf_*=翻回执法之后。正对照＝*_good 全程该 0，负对照＝*_bogus 全程该非 0。)
say "K95 load_rc=$LOADRC ctrl_rc=$CLOADRC dry_fail=$DRY af_md5=$AFMD5 af_bytes=$AFBY pre_new=$PREn pre_good=$PREg pre_bogus=$PREb ct_new=$CTn ct_good=$CTg post_new=$POSTn post_bogus=$POSTb post_good=$POSTg enf_new=$P2n enf_bogus=$P2b label_ok=$LBLOK chcon_rc=$CH1/$CH2 read_rc=$RD write_rc=$WR exec_rc=$EX execold_rc=$EO getattr_rc=$GA chcon_after_rc=$CA setenf0_rc=$S0 clean_rc=$RMRC residue_labelled=$RES"
echo "END up=$(UP) verdict=$V enf=$(cat /sys/fs/selinux/enforce 2>&1)" >> $L
sync
