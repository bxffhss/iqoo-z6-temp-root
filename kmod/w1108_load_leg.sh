#!/system/bin/sh
# w1108_load_leg.sh v2 —— 装运行期策略这一格（用户 11-02 明确点头写 /sys/fs/selinux/load）。
#   v1(第 90 发)用的是 `cat pol.new > /sys/fs/selinux/load` ⇒ 得到 `cat: xwrite: Invalid argument`。
#   ★v1 的读数**不能**读成"内核拒了这份 delta"：一手凭据＝设备自己那份 5.4.281 源码——
#     sel_load_ops 只有 .write/.llseek(没有事务/提交语义)、sel_write_load 明写 "No partial writes."
#     (`*ppos!=0 ⇒ -EINVAL`)、而 policydb_read 的 next_entry 剩余字节不够就返回 -EINVAL
#     ⇒ 内核把**每一次 write() 当成一整份策略图**。cat 是分块写的，第一刀递进去的是**截断的图**，
#     我们那 3 条 delta 的内容**从没被评过**。⇒ 这一格按"未测"收回，v2 换形状。
#   ★v2 的形状＝`dd bs=<整份字节数> count=1`：一条记录＝一次 write()，且先对**普通文件**干跑一次，
#     用"records out=1 ＋ 落点 md5 与源相同"证这条工具在这台机上确实一次交整份，再去碰 load 节点。
#   ★v2 还加了一条**同窗 A/B 对照**：先把"设备上刚导出、逐字节就是厂商当前生效那份"的 pol.orig 装一次。
#     它语义上是空操作(同一份图)，却能把两种解释分开：
#       对照 rc=0 ⇒ 运行期装载这条路本身通 ⇒ delta 若红就是**内容**被拒；
#       对照同错 ⇒ 墙在"运行期整图装载"这一层(与我们的 delta 无关)，delta 那一格仍算未测。
#   ★安全线：只装"PC 侧已被 w1105/w1109 差分证成『厂商＋恰好 3 条、零删除、零削弱』"的那一份；
#     md5/字节数对不上就地拒绝；pol.after **无论装载成败都导出**(v1 在失败分支提前退出，留下
#     AF_ADDED=0/AF_REMOVED=72814 那种假账——那是因为 after 根本没导出，不是策略少了 72814 条)。
#   ★A/B 的不对称是被迫的，写在这里免得被读成同条件对照：装载只能在 Permissive 段做
#     (执法态 `> load` 被拒＝§6.445②/§6.447③)，而"放行/拦住"只有执法态才算行为 ⇒
#     装前侧＝Permissive 下同一动作的 avc denied 记录(permissive=1，记不拦但记)；装后侧＝执法下的 rc。
#   ★v3(第 93 发已用**正例**证明这条能装)：①`onedd` 把 dd 的两股流并成一份(92 发那条假拒的根因＝
#     toybox dd 的 `1+0 records in/out` 在 stderr，闸却查 stdout)；②装前/装后行为判据从 `$D`(shell 自家
#     `shell_data_file`，厂商规则本来就有⇒没有判别力)换成 delta 真正要开的 **`/data/adb`(adb_data_file)** 三格，
#     并当场删干净复证；③`COUNTS` 里那个一词两义(`DRY_SHAPE_OK` 既当布尔又当计数)改成 `DRY_FAIL`。
L=/data/local/tmp/w1108_load.out
D=/data/local/tmp/w1107
NEW=$D/pol.new; ORIG=$D/pol.orig; EXPECT=$D/expect.txt; POLA=$D/pol.after
: > $L
UP() { cut -d' ' -f1 /proc/uptime; }
AVCN() { dmesg 2>/dev/null | grep -acE 'avc: +denied.*(capability|adb_data_file)'; }
say() { echo "$*" >> $L; }
# 一条 dd：★stdout 与 stderr **合进同一份文件**($4)，返回码进全局 RC。
#   为什么必须合：11-02 第 92 发那次"形状闸红"就是我自己分了两份文件——**toybox dd 把
#   `1+0 records in/out` 打在 stderr**，我却只 grep stdout 那份(结果是空的)⇒ 一把本来该放行的闸
#   把自己的合法输入拒了(例 219 那一族：拒人的闸必须跑"合法输入必须过"的正对照)。
onedd() { dd if=$1 of=$2 bs=$3 count=1 >$4 2>&1; RC=$?; }
errtxt() { head -c 140 $1 2>&1 | tr '\n' '|'; }

say "BEGIN v2 up=$(UP) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)"
#   ★本次 boot 的身份证人：链在派单前后各读一次同一个值，三方相等才算"这条腿是在这扇窗里跑的"。
#     第 91 发就是栽在"跨 boot 同名旧产物里已经有 END 行"⇒ 链第 1 轮就判定跑完、把陈件当读数拉走，
#     随后重启把**真在写**的这条腿拦腰杀掉(一手＝设备上那份 551 B 的腿件停在 `PRE_mkdir_rc=0`)。
say "LEG_BOOTID=[$(cat /proc/sys/kernel/random/boot_id 2>&1)] LEG_UP_AT_BEGIN=$(UP)"
say "ARM=装载 pol.new(整份一次 write 进 /sys/fs/selinux/load)→装前先装 pol.orig 当对照→再导出→翻执法→行为格"
# --- 1) 装载前三把硬闸：文件在、大小=登记、md5=登记 ---
if [ ! -f $NEW ]; then say "[x] 设备上没铺 pol.new ⇒ 不装载"; chmod 666 $L; echo "END up=$(UP) verdict=未装载" >> $L; exit 0; fi
NM=$(md5sum $NEW 2>/dev/null | cut -d' ' -f1); NS=$(wc -c < $NEW 2>/dev/null)
EM=$(sed -n 's/^MD5=//p' $EXPECT 2>/dev/null); ES=$(sed -n 's/^BYTES=//p' $EXPECT 2>/dev/null)
say "NEW_md5=$NM bytes=$NS  登记 md5=$EM bytes=$ES"
if [ "$NM" != "$EM" ] || [ "$NS" != "$ES" ]; then
    say "[x] 设备上那份 pol.new 与链的登记不符 ⇒ **拒绝装载**(装载面必须＝被离线差分验过的那一份)"
    chmod 666 $L; echo "END up=$(UP) verdict=未装载" >> $L; exit 0
fi
OM=""; OS=""
if [ -f $ORIG ]; then OM=$(md5sum $ORIG 2>/dev/null | cut -d' ' -f1); OS=$(wc -c < $ORIG 2>/dev/null); fi
say "ORIG_md5=$OM bytes=$OS (对照面＝设备上刚导出的那份，期望 md5=282a68611a2f36321a153fc0102f9ca0 bytes=1356948)"
# --- 2) 装前证人（Permissive：不拦但记 denied） ---
BEFORE=$(AVCN); say "AVC_BEFORE=$BEFORE up=$(UP)"
touch $D/pre_adb_file 2>>$L; say "PRE_touch_own_rc=$? (这一格是 $D 自己＝shell 家的对照，装前装后都该 0，不是判据)"
mkdir $D/pre_adb_dir 2>>$L; say "PRE_mkdir_own_rc=$?"
rm -rf $D/pre_adb_file $D/pre_adb_dir 2>/dev/null
#   ★真正该被 delta 翻正的那一格在 /data/adb(adb_data_file)：v1 把 PRE/POST 都写在了 $D 里，
#     而 $D 是 shell 自家的 shell_data_file、规则本来就有 ⇒ 那条 POST_touch_rc=0 根本没有判别力(#227/#228 的账)。
ls -d /data/adb >$D/pre_lsadb.txt 2>&1; say "PRE_ls_adb_rc=$? 内容=[$(head -1 $D/pre_lsadb.txt 2>&1 | cut -c1-60)]"
touch /data/adb/z6probe_pre 2>>$L; say "PRE_adb_touch_rc=$? (Permissive 下 MAC 记不拦 ⇒ 期望 0；这条只是装前形状，不当判据)"
rm -f /data/adb/z6probe_pre 2>/dev/null
AFTER0=$(AVCN); say "AVC_AFTER_PROBE=$AFTER0 (比 BEFORE 大＝记到这两次 denied；不增大⇒这一格未测)"
say "PRE_SYSERVER=[$(pidof system_server 2>&1 | tr -s ' ' | cut -c1-30)]"
sync
# --- 3) ★形状闸：先对普通文件干跑，证"一次交整份"在这台机上成立，才允许碰 load ---
DRYBAD=0
for spec in "ORIG|$ORIG|$OS|$D/dry_orig.bin" "NEW|$NEW|$NS|$D/dry_new.bin"; do
    TAG=$(echo "$spec" | cut -d'|' -f1); F=$(echo "$spec" | cut -d'|' -f2); B=$(echo "$spec" | cut -d'|' -f3); T=$(echo "$spec" | cut -d'|' -f4)
    if [ -z "$B" ] || [ "$B" -le 0 ]; then say "DRY_$TAG=跳过(没拿到字节数)"; DRYBAD=1; continue; fi
    onedd "$F" "$T" "$B" $D/dry_$TAG.out
    say "DRY_$TAG rc=$RC dd自报=[$(errtxt $D/dry_$TAG.out)] 落点字节=$(wc -c < $T 2>/dev/null) 落点 md5=$(md5sum $T 2>/dev/null | cut -d' ' -f1) 源 md5=$(md5sum $F 2>/dev/null | cut -d' ' -f1)"
    [ "$RC" = 0 ] || { say "[x] DRY_$TAG dd 本身没跑通 ⇒ 不许去碰 load"; DRYBAD=1; }
    grep -qa '1+0 records out' $D/dry_$TAG.out 2>/dev/null || { say "[x] DRY_$TAG 没记到『1+0 records out』⇒ 它不是一次写完，形状不成立"; DRYBAD=1; }
    #   ★这条不是凑数：11-02 现场量过——把源截到 700000 B 再按 bs=1356984 跑，toybox dd 印的是
    #     『0+1 records in／0+1 records out』，而**落点 md5 仍与(那份短)源相同** ⇒ 光比 md5 抓不住短读，
    #     必须同时要求"落点字节数＝整份字节数"(设备侧正/负对照各一次，0 枪)。
    [ "$(wc -c < $T 2>/dev/null)" = "$B" ] || { say "[x] DRY_$TAG 落点字节≠$B ⇒ 交出去的不是整份"; DRYBAD=1; }
    [ "$(md5sum $T 2>/dev/null | cut -d' ' -f1)" = "$(md5sum $F 2>/dev/null | cut -d' ' -f1)" ] || { say "[x] DRY_$TAG 落点内容与源不同 ⇒ 形状不成立"; DRYBAD=1; }
done
DRY=$DRYBAD
say "DRY_SHAPE_OK=$([ "$DRY" = 0 ] && echo 1 || echo 0) (★这条不成立，下面两次装载都不做)"
# --- 4) 装载（对照在前、delta 在后）；★读数看 errno 的文字，不许拿 rc 当 errno ---
CLOAD=0; CLOADRC=-1; LOADRC=-1
if [ "$DRY" = 0 ]; then
    if [ -n "$OS" ] && [ -f $ORIG ]; then
        onedd "$ORIG" /sys/fs/selinux/load "$OS" $D/load_ctrl.out
        CLOADRC=$RC; CLOAD=1
        say "★CTRL_LOAD_rc=$CLOADRC bs=$OS dd自报与errno文字=[$(errtxt $D/load_ctrl.out)] up=$(UP) enf_now=$(cat /sys/fs/selinux/enforce 2>&1) syserver=[$(pidof system_server 2>&1 | tr -s ' ' | cut -c1-30)]"
    else
        say "★CTRL_LOAD=未做(对照面不在) ⇒ delta 的归因少一条腿"
    fi
    onedd "$NEW" /sys/fs/selinux/load "$NS" $D/load_delta.out
    LOADRC=$RC
    say "★DELTA_LOAD_rc=$LOADRC bs=$NS dd自报与errno文字=[$(errtxt $D/load_delta.out)] up=$(UP) enf_now=$(cat /sys/fs/selinux/enforce 2>&1) syserver=[$(pidof system_server 2>&1 | tr -s ' ' | cut -c1-30)]"
    if [ "$LOADRC" != 0 ]; then
        say "[x] delta 这一次整图写被内核拒(errno 见上面的文字)⇒ 策略没换成 delta；这不是『成功但没生效』，也不是『内容被拒』直到对照那一条也读完"
    fi
else
    say "[x] 形状闸没过 ⇒ 两次装载都**没做**，这一格按未测收，不许写『被拒』"
fi
sync
# --- 5) 再导出（成败都做：装载失败也要有"策略没变"的独立证人） ---
cat /sys/fs/selinux/policy > $POLA 2>$D/after.err
say "AFTER_export_rc=$? bytes=$(wc -c < $POLA 2>&1) md5=$(md5sum $POLA 2>&1 | cut -d' ' -f1) orig_md5=$OM"
say "AFTER_HEAD16=$(od -An -tx1 -N16 $POLA 2>&1 | tr -s ' ')"
chmod a+r $POLA 2>/dev/null
# --- 6) 翻回执法（**单向**：§6.441 写不回 0） ---
echo 1 > /sys/fs/selinux/enforce 2>>$L
say "ENFORCE_flip_rc=$? enf_now=$(cat /sys/fs/selinux/enforce 2>&1) up=$(UP)"
# --- 7) 装后行为格（执法态）：该翻正 / 不该变坏 / 负对照仍须被拒 ---
#   ★判据面＝`/data/adb`(adb_data_file，delta 里那两条 dir/file)＋`ls 0771 目录`(dac_read_search 那一族)；
#     $D 里那两格(shell 自家)只当"没变坏"的对照，不许当 delta 生效的证据(v1 就错在这里)。
ls -d /data/adb >$D/post_lsadb.txt 2>&1; say "★POST_ls_adb_rc=$? 内容=[$(head -1 $D/post_lsadb.txt 2>&1 | cut -c1-60)]"
touch /data/adb/z6probe_post 2>>$L; say "★POST_adb_touch_rc=$? (该翻正：delta 给了 adb_data_file:dir add_name/create＋file create)"
mkdir /data/adb/z6probe_dir 2>>$L; say "★POST_adb_mkdir_rc=$? (该翻正：dir create/add_name)"
rm -f /data/adb/z6probe_post 2>/dev/null; RC_CLEAN=$?
rmdir /data/adb/z6probe_dir 2>/dev/null; say "CLEAN_adb_rc=$RC_CLEAN/rmdir=$? 残留=[$(ls /data/adb 2>&1 | tr '\n' '|' | cut -c1-80)]"
touch $D/post_own_file; say "POST_own_touch_rc=$? (对照：装前装后都该 0)"
mkdir $D/post_own_dir;  say "POST_own_mkdir_rc=$? (对照)"
rm -f $D/post_own_file 2>/dev/null; rmdir $D/post_own_dir 2>/dev/null
mkdir -p $D/w0777 && chmod 777 $D/w0777
touch $D/w0777/ok 2>&1; say "CTRL_0777_touch_rc=$? (不该变坏：装前装后都该 0)"
#   负对照：我们**没有**给 capability2{mac_override/mac_admin} ⇒ 执法态下把 enforce 写回 0 必须仍被拒。
echo 0 > /sys/fs/selinux/enforce 2>>$L
say "CTRL_setenforce0_rc=$? enf_after_ctrl=$(cat /sys/fs/selinux/enforce 2>&1) (期望 rc≠0 且仍=1；若真变 0 ⇒ 我们放得太宽，红)"
AFTER1=$(AVCN); say "AVC_NOW=$AFTER1 (执法态下 dmesg 可能被 CAP_SYSLOG 挡＝§6.452，取不到记未测)"
rm -f $D/dry_orig.bin $D/dry_new.bin 2>/dev/null
chmod -R a+r $D 2>/dev/null; chmod 666 $L 2>/dev/null
sync
V=装载失败
[ "$LOADRC" = 0 ] && V=delta已装载
[ "$DRY" != 0 ] && V=未装载(形状闸红)
#   ★★93 发一手：这一行原本印 `DRY_SHAPE_OK=$DRY`＝把"失败计数(0＝好)"塞进上面那个**布尔同一个词**
#     ⇒ 链按 `DRY_SHAPE_OK=0` 一 grep 就命中这里，当场印出一条**假"形状闸红"**（真读数在上一行＝1）。
#     一个词只能有一个意思(#183/例 219 同族)：计数改名 DRY_FAIL，布尔只由 `DRY_SHAPE_OK=` 那行负责。
say "COUNTS CTRL_LOADED=$CLOAD CTRL_rc=$CLOADRC DELTA_rc=$LOADRC DRY_FAIL=$DRY AFTER_md5=$(md5sum $POLA 2>/dev/null | cut -d' ' -f1)"
echo "END up=$(UP) verdict=$V enf=$(cat /sys/fs/selinux/enforce 2>&1)" >> $L
sync
