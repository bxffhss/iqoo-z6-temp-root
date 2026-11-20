#!/bin/bash
# ★★92 发的**唯一变化**＝修第 91 发我自己那个仪器洞(那一发因此白烧，读数＝未测，md §6.518)：
#   91 发派第二条腿前**没删上一 boot 留下的同名腿件** `w1108_load.out`(里面已经有 `END up=`)
#   ⇒ 就绪闸第 1 轮就判"跑完"、把 90 发的陈件当读数拉回 PC，随后链自己 reboot 把**真在写**的 v2 腿
#   拦腰杀掉(一手＝设备上那份 551 B 的腿件停在 `PRE_mkdir_rc=0`，而链拉回的是 v1 文本＋v1 的 up 值)。
#   ⇒ 92 发加三件：①派单前 `rm` 后**复证已删**(删与复证同源，§6.155 那一族)；②就绪判据要求**同一份新件里**
#     既有 `BEGIN v2` 又有 `END up=`(只查 `END up=` 会被陈件白过)；③**boot 身份**＝链读 `boot_id` 两次
#     ＋腿自印 `LEG_BOOTID`，三者相等才算"这条腿在这扇窗里跑过"；不相等⇒这一格记未测。
# ★★93 发的**唯一变化**＝修第 92 发那两处我自己的仪器错(92 发本身＝未测：腿在窗里跑完了全程、
#   boot 身份三方相等，但**形状闸把自己的合法输入拒了**，两次装载都没做；md §6.518)：
#   ①`onedd` 原先把 dd 的 stdout 与 stderr 分成两份文件，而 **toybox dd 把 `1+0 records in/out` 打在 stderr**
#     ⇒ 那条 `grep 1+0 records out` 查的是空的那份 ⇒ 假拒(例 219 本尊：拒人的闸必须有"合法输入必过"的正对照)。
#     93 发＝**两股流并成一份**，`grep` 与 `dd自报[]` 都读同一份；这条 0 枪先在设备上量正/负两格。
#   ②行为判据原先写在 `$D`(shell 自家的 shell_data_file，规则本来就有)⇒ 那条 `POST_touch_rc=0` **没有判别力**。
#     93 发把它换成 delta 真正要开的那一格＝**`/data/adb`(adb_data_file)**：`POST_ls_adb_rc`／`POST_adb_touch_rc`／
#     `POST_adb_mkdir_rc` 该由红翻绿；`$D` 里那两格降级成"没变坏"的对照；探针件当场 `rm` 并复证残留。
#   ★92 发白捡的一条硬读数(与装载无关)：没装载时再导出的 `pol.after` 与厂商件**逐字节相同**
#     (`282a6861…`/1,356,948 B，`AF_ADDED=0 AF_REMOVED=0`)⇒ 这条以后可以当"策略没被动过"的证人形状。
# ★★94 发这一枪买的是 **3b 策略格**（选型与逐行实测见 md §6.520）：把 LSPosed/Zygisk Next 的
#   `sepolicy.rule` 里"这台机的活策略能表达"的那 9 行**原样**装进运行期活策略。
#   与 93 发的三处不同：①规则文本换件（`kmod/sepolicy_delta/rules_community9.txt`＝`472e81e0…`，
#     9 行 allow，其余注释）；②**判据换语义**——这批里 4 行会并进厂商已有节点（`MERGED=4`），
#     所以三元组行差分必然出现"旧写法被去掉"，那不是削弱是加宽 ⇒ 离线闸从"−0"改成机械的
#     **零削弱证明**（每条被去掉的写法，同 key 必须以"旧权限⊆新权限"的形式回来，`ZERO_WEAKEN=0`）；
#     ③**行为侧预期反过来**：这批规则一条都没给 `shell` ⇒ 执法态下 `/data/adb` 那三格**必须仍然红**；
#     它们要是绿了，说明装进去的不是我以为是的那批（链里按这个方向出了一格 `SHELL_STILL_RED=`）。
#   ★装载前把风险写死（量产机）：这 9 条会在**翻回执法之后、重启之前**这几秒里真的生效——
#     `system_server` 拿到 `process execmem`(关 W^X)与 `apk_data_file:file execute`(可执行 app 落地文件)、
#     `zygote` 拿到 `capability sys_chroot` 与 `fs_type:filesystem unmount`。我不去触发它们，
#     窗口一关(reboot)就全部消失；不进包、不接进任何跑法。
# w1117_shot94.sh —— 第 94 发＝**3b：把社区模块的 sepolicy.rule 装进活策略"真装载尝试"**（v2 形状；装载动作＝用户 11-02 已点头那一格）。
#   为什么第 89/90 发不算试过：那两发用的是 `cat pol.new > /sys/fs/selinux/load`。一手凭据(设备自己那份
#   5.4.281 源码，11-02 现读)＝sel_load_ops 只有 .write/.llseek(没有提交语义)、sel_write_load 明写
#   "No partial writes."(`*ppos!=0 ⇒ -EINVAL`)、policydb_read 的 next_entry 剩余字节不够就 -EINVAL
#   ⇒ 内核把**每一次 write() 当成一整份图**。cat 分块写 ⇒ 第一刀递进去的是截断的图 ⇒ **delta 的内容从没被评过**。
#   ⇒ 90 发那条 `cat: xwrite: Invalid argument` 只证明"分块的形状内核不认"，不证明"我们的 delta 被拒"。
#   v2 的两处改动：①装载器换成 `dd bs=<整份字节数> count=1`(一条记录＝一次 write)，且**先对普通文件干跑**
#   证形状(records out=1 ＋ 落点字节数＝整份 ＋ 落点 md5＝源)；②加**同窗对照**：先把设备上刚导出的
#   pol.orig(＝厂商正在生效的那份，逐字节)装一次——它语义上是空操作，却把"运行期整图装载这条路根本不通"
#   与"我们这份 delta 的内容被拒"分开(第 90 发正因为缺这条对照才只能记未测)。
#   ★读法(开枪前写死，五支，不许互相顶替)：
#     ①`DRY_SHAPE_OK=0` ⇒ 两次装载都没做 ⇒ 记**未测**，不许写"被拒"；
#     ②`CTRL_LOAD_rc=0` 且 `DELTA_LOAD_rc≠0` ⇒ 装载机制通、**我们这份图的内容**被内核拒＝一手的"内核不认
#       我们序列化出来的东西"，是结论不是失败；之后拿 errno 文字定位(libsepol 3.4 制式 vs 内核 policyvers)；
#     ③`CTRL_LOAD_rc≠0` 与 `DELTA_LOAD_rc` 同一个 errno ⇒ 墙在"运行期整图装载"这一层(与 delta 无关)，
#       delta 那一格仍**未测**；此时看 errno 文字＋`enforce`/`syserver` 是否还活着；
#     ④两条都 0 ⇒ 装载成立：`pol.after` 导回来在构建机上 dump，必须＝ `pol.orig` 的 allow 全集**＋恰好 3 条、零删除**；
#       行为侧再看执法下 `POST_touch_rc=0`/`POST_mkdir_rc=0`，且负对照 `CTRL_setenforce0_rc≠0`、`CTRL_0777_touch_rc=0`；
#     ⑤`AVC_BEFORE==AVC_AFTER_PROBE`(记不到 denied) ⇒ 装前那一侧记未测(dmesg 通道有间歇的洞＝§6.19x，不是否据)。
#   ★代价与恢复：量产机。装载只在内存里、**没有持久化**，`adb reboot` 就回到厂商策略(第 6 步必做并复核基线)。
#     风险要写清：运行期 `security_load_policy` 在 Android 上很少走(开机那次是 `!initialized` 分支)，本发走的是
#     带 `sidtab_convert` 的重载分支；若内核在这条路上崩＝整机复位，代价＝多摔一次机器，delta 不残留。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT=${SHOT:-94}
RM_CLI=hermes-remote1/cli.py; RM_CFG=hermes-remote1/config.json
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
REXEC() { HRMT_CLI=$RM_CLI W682_T=280 PYTHONUTF8=1 python kmod/w682_rr.py "$1" 2>&1 | tr -d '\r'; }
RPUSH() { HRMT_CLI=$RM_CLI python $RM_CLI --config $RM_CFG put "$1" "$2" 2>&1 | tail -1; }
RGET()  { HRMT_CLI=$RM_CLI python $RM_CLI --config $RM_CFG get  "$1" "$2" 2>&1 | tail -1; }
if [ -n "${MSYS_NO_PATHCONV+set}" ]; then echo "[x] MSYS_NO_PATHCONV 被定义了(哪怕空值) ⇒ 拒跑(它会让离线自测假红；见例 218)"; exit 3; fi

echo "[1/6] 离线总闸(链内现跑)"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪(红的是闸就补前置，不是改闸)"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

L1REPO=kmod/w1107_pre_leg.sh;  L1DEV=/data/local/tmp/w1107_pre_leg.sh;  L1OUT=/data/local/tmp/w1107_pre.out
L2REPO=kmod/w1108_load_leg.sh; L2DEV=/data/local/tmp/w1108_load_leg.sh; L2OUT=/data/local/tmp/w1108_load.out
DDEV=/data/local/tmp/w1107
echo "[2/6] 铺两腿＋四把闸(权限／plain s0／两端 md5／设备 mksh sh -n)"
M1=$(md5sum $L1REPO | cut -d' ' -f1); M2=$(md5sum $L2REPO | cut -d' ' -f1)
MSYS_NO_PATHCONV=1 adb push $L1REPO $L1DEV 2>&1 | tail -1
MSYS_NO_PATHCONV=1 adb push $L2REPO $L2DEV 2>&1 | tail -1
A "chmod 755 $L1DEV $L2DEV; mkdir -p $DDEV" >/dev/null
gate() { local P L D S
    P=$(A "ls -l $1 2>/dev/null" | awk 'NR==1{print $1}'); L=$(A "ls -Zd $1 2>/dev/null" | awk 'NR==1{print $1}')
    D=$(A "md5sum $1 2>/dev/null" | cut -d' ' -f1)
    S=$(MSYS_NO_PATHCONV=1 adb shell "/system/bin/sh -n $1 >/dev/null 2>&1 && echo SHN=OK || echo SHN=BAD" 2>&1 | tr -d '\r')
    echo "  $3 权限=$P 标签=$L 设备md5=$D 本机md5=$2 $S"
    [ "${P:3:1}" = x ] || { echo "[x] $3 没 x 位 ⇒ 不开枪"; exit 1; }
    case "$L" in *:s0) : ;; *) echo "[x] $3 标签不是 plain s0 ⇒ 不开枪(#114)"; exit 1 ;; esac
    [ "$D" = "$2" ] || { echo "[x] $3 设备上不是本机这支(§6.155)⇒ 不开枪"; exit 1; }
    grep -q SHN=OK <<<"$S" || { echo "[x] $3 没过设备语法闸 ⇒ 不开枪"; exit 1; } }
gate "$L1DEV" "$M1" "只读导出腿"
gate "$L2DEV" "$M2" "装载腿 v2"
#   ★第五把闸(形状闸的**前置**，0 枪就能量)：装载腿里那句 grep 的词必须在**这台设备这台 toybox**上现印得出来，
#     不然形状闸会假红/假绿(11-02 19:2x 已现测过一次，本发在派腿前再认一遍)。落盘只碰 /data/local/tmp 的临时件。
S=$(A "cd /data/local/tmp; dd if=/dev/zero of=.w1117_z bs=1356984 count=1 2>&1 | tr '\n' '|'; rm -f .w1117_z" | tr -d '\r')
echo "  设备 dd 形状现测=$S"
grep -q '1+0 records out' <<<"$S" || { echo "[x] 设备 dd 没印『1+0 records out』⇒ 装载腿的形状闸词不对，先修词再开枪"; exit 1; }

echo "[3/6] 开窗(1 枪＝punch)＋派**第一段只读腿**(结构上不可能写策略)"
LEG1ONLY=1 LEG1=$L1DEV LEG1OUT=$L1OUT LEG1MD5="$M1" I_KNOW=1 bash kmod/go.sh > $EV/w1117_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1117_shot${SHOT}_go.log | sed 's/^/  go: /'
A "cat $L1OUT 2>/dev/null" > $EV/w1107_pre_shot${SHOT}.out 2>&1
grep -aE 'BEGIN|ARM=|EXPORT_rc|HEAD16|NEG_CTRL|PRE_SYSERVER|\[x\]|END up=' $EV/w1107_pre_shot${SHOT}.out | cut -c1-200 | sed 's/^/    /'
MSYS_NO_PATHCONV=1 adb pull $DDEV/pol.orig $EV/w1117_pol.orig_${SHOT} 2>&1 | tail -1 | sed 's/^/  pull: /'
ORIG=$(md5sum $EV/w1117_pol.orig_${SHOT} 2>/dev/null | cut -d' ' -f1); OB=$(wc -c < $EV/w1117_pol.orig_${SHOT} 2>/dev/null)
echo "  本机这份 pol.orig=$OB B md5=$ORIG (厂商件应＝282a6861…/1356948 B)"
[ "$GO" = 0 ] || { echo "[x] go.sh rc=$GO ⇒ 先看日志；**不装载**"; exit 1; }

echo "[4/6] 离线差分闸(社区那 9 条)：七把全过才推 pol.new(在构建机上跑，本步不碰设备)"
RPUSH "$EV/w1117_pol.orig_${SHOT}" pol.shot$SHOT >/dev/null
RPUSH kmod/sepolicy_delta/rules_community9.txt rules9_$SHOT.txt >/dev/null
RPUSH kmod/w1116_verify_community.sh w1116_verify_community.sh >/dev/null
RMDS=$(md5sum kmod/sepolicy_delta/rules_community9.txt | cut -d' ' -f1)
RExec=$(REXEC "cp /home/lucy/pol.shot$SHOT /home/lucy/pol.orig 2>/dev/null; cp /home/lucy/rules9_$SHOT.txt /home/lucy/rules9.txt 2>/dev/null; md5sum /home/lucy/rules9.txt | cut -d' ' -f1; bash /home/lucy/w1116_verify_community.sh pol.orig rules9.txt")
echo "$RExec" | grep -aE '^(ORIG_MD5|RT_|INSERTED|MERGED|RULES_IN_FILE|C_ADDED|C_REMOVED|ZERO_WEAKEN|NEW_|VERDICT)' | sed 's/^/    /' | tee $EV/w1117_verify_shot${SHOT}.txt
RM=$(echo "$RExec" | grep -ac "^$RMDS")
M1OK=$(echo "$RExec" | grep -ac '^RT_ADDED=0'); M2OK=$(echo "$RExec" | grep -ac '^RT_REMOVED=0')
M3OK=$(echo "$RExec" | grep -ac '^INSERTED=5'); M4OK=$(echo "$RExec" | grep -ac '^MERGED=4')
M5OK=$(echo "$RExec" | grep -ac '^ZERO_WEAKEN=0'); M6OK=$(echo "$RExec" | grep -ac '^VERDICT=ok')
M7OK=$(echo "$RExec" | grep -ac "^ORIG_MD5=$ORIG"); M8OK=$(echo "$RExec" | grep -ac '^RULES_IN_FILE=9')
NEWM=$(echo "$RExec" | sed -n 's/^NEW_MD5=//p'); NEWB=$(echo "$RExec" | sed -n 's/^NEW_BYTES=//p')
echo "  规则文本两端 md5：本机=$RMDS 远端=$(echo "$RExec" | sed -n 's/^\([0-9a-f]\{32\}$\)/\1/p' | head -1) ⇒ $( [ "$RM" = 1 ] && echo 一致 || echo **不一致** )"
if [ "$RM$M1OK$M2OK$M3OK$M4OK$M5OK$M6OK$M7OK$M8OK" != "111111111" ]; then
    echo "[x] 离线九把没全过(规则文本两端一致/RT±0/INSERTED=5/MERGED=4/零削弱/VERDICT/ORIG 一致/RULES_IN_FILE=9) ⇒ **不装载**，直接关窗；这一发记『未装载』"
    A "svc power stayon false" >/dev/null; adb reboot; adb wait-for-device; sleep 20
    echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules")"
    echo "SHOT${SHOT}_DONE verdict=未装载(离线闸没过)"; exit 1
fi
RGET new.pol "$EV/w1117_pol.new_${SHOT}" >/dev/null
NM=$(md5sum $EV/w1117_pol.new_${SHOT} | cut -d' ' -f1); NB=$(wc -c < $EV/w1117_pol.new_${SHOT})
echo "  取回 pol.new=$NB B md5=$NM 远端报 md5=$NEWM bytes=$NEWB ⇒ $( [ "$NM" = "$NEWM" ] && [ "$NB" = "$NEWB" ] && echo 两端一致 || echo 不一致)"
[ "$NM" = "$NEWM" ] && [ "$NB" = "$NEWB" ] || { echo "[x] pol.new 两端不一致 ⇒ 不装载"; exit 1; }

echo "[5/6] ★推 pol.new＋派装载腿 v2(删陈件并复证→干跑证形状→装 pol.orig 当对照→装 pol.new)"
MSYS_NO_PATHCONV=1 adb push $EV/w1117_pol.new_${SHOT} $DDEV/pol.new 2>&1 | tail -1 | sed 's/^/  /'
A "printf 'MD5=%s\nBYTES=%s\n' $NM $NB > $DDEV/expect.txt; chmod 666 $DDEV/pol.new $DDEV/expect.txt; echo 派腿前域=\$(cat /proc/self/attr/current) > $DDEV/dispatch_ctx.txt" >/dev/null
#   ★★91 发那一课的修复①：先删**上一 boot 留下的同名腿件**并**复证已删**(删与复证同一个来源)，
#     否则就绪闸会白过(见文件头那段)。删不掉就不派腿、直接关窗——这条比"少跑一发"贵。
A "rm -f $L2OUT" >/dev/null
GONE=$(A "ls -l $L2OUT 2>&1")
case "$GONE" in *"No such file"*) : ;; *) echo "[x] 腿件删不掉(现读=[$GONE]) ⇒ **不派腿**(派了也是拿陈件当读数)"; A "svc power stayon false" >/dev/null; adb reboot; exit 1 ;; esac
echo "  派腿前复证：$GONE"
BOOT0=$(A "cat /proc/sys/kernel/random/boot_id 2>&1")
echo "  本 boot 身份 boot_id(派前)=$BOOT0"
echo "  派装载腿: $(A "am force-stop com.suw.manager")$(A "am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"@sushd:$L2DEV\"" | tail -1)"
#   ★修复②：就绪＝**同一份新件里** `BEGIN v2` 与 `END up=` 都在；只看 `END up=` 就是 91 发那个洞。
ROUND=0; READY=0
for i in $(seq 1 80); do sleep 3; ROUND=$i
    B=$(A "grep -acF 'BEGIN v2' $L2OUT 2>/dev/null" | tr -dc '0-9')
    E=$(A "grep -acF 'END up=' $L2OUT 2>/dev/null" | tr -dc '0-9')
    if [ "${B:-0}" -ge 1 ] && [ "${E:-0}" -ge 1 ]; then READY=1; echo "  腿跑完(第 $i 轮：新件里 BEGIN v2 与 END 齐)"; break; fi
    if [ "${B:-0}" = 0 ] && [ "${E:-0}" -ge 1 ]; then echo "  [!] 第 $i 轮：件里有 END 却没有 BEGIN v2 ⇒ **陈件**，继续等真这一份"; fi
done
[ "$READY" = 1 ] || echo "  [!] 等满 $ROUND 轮没等到新件两行 ⇒ 这一格记**未测**(『没输出』既不当通过也不当被拒)"
A "cat $L2OUT 2>/dev/null" > $EV/w1108_load_shot${SHOT}.out 2>&1
#   ★修复③：boot 身份三方相等才算"这条腿在这扇窗里跑过"
BOOT1=$(A "cat /proc/sys/kernel/random/boot_id 2>&1")
LB=$(sed -n 's/^LEG_BOOTID=\[\(.*\)\].*/\1/p' $EV/w1108_load_shot${SHOT}.out 2>/dev/null | head -1)
echo "  ★boot 身份三方：派前=$BOOT0 读回后=$BOOT1 腿自印=$LB ⇒ $( [ -n "$LB" ] && [ "$BOOT0" = "$LB" ] && [ "$BOOT1" = "$LB" ] && echo 同一＝这腿真在这扇窗里跑过 || echo **不相等⇒这一格未测** )"
grep -aq 'LEG_BOOTID' $EV/w1108_load_shot${SHOT}.out || echo "  [!] 新件里没有 LEG_BOOTID 行 ⇒ 跑的不是带身份证这支腿，读数一律按未测处理"
#   ★★92 发那一课：任何"腿自己印的计数/形状"词都要先在**设备上**跑过正对照，这里再核一次
#     dd 的词形(链在 [2/6] 已经现认过一遍，这一格是把"闸红到底红在哪"写进证件)
grep -aq 'DRY_SHAPE_OK=0' $EV/w1108_load_shot${SHOT}.out && echo "  [!] 形状闸红 ⇒ 两次装载都没做，这一格＝未测(读上面的 dd自报[] 看它到底印了什么)"
grep -aq '★POST_adb_touch_rc=' $EV/w1108_load_shot${SHOT}.out || echo "  [!] 新件里没有 /data/adb 那三格行为判据 ⇒ 腿不是 v3 那支，按未测处理"
grep -aE 'BEGIN v2|LEG_BOOTID|ARM=|NEW_md5|ORIG_md5|AVC_|PRE_|DRY_|★CTRL_LOAD|★DELTA_LOAD|AFTER_|ENFORCE_flip|★POST_|POST_|CTRL_|\[x\]|COUNTS|END up=' $EV/w1108_load_shot${SHOT}.out | cut -c1-240 | sed 's/^/    /'
#   ★pull 清单由**腿自己的写点**推出来，不手数(§6.516 那条)：整目录拉回，缺哪个文件当场看得见
MSYS_NO_PATHCONV=1 adb pull $DDEV $EV/w1117_records_shot${SHOT} 2>&1 | tail -1 | sed 's/^/  pull: /'
AFTER=$EV/w1117_records_shot${SHOT}/pol.after
[ -f "$AFTER" ] || { echo "  [!] pol.after 不在(=$AFTER) ⇒ 装后那一侧记未导出，不许拿 AF_* 的 0 当结论"; }
if [ -f "$AFTER" ]; then
RPUSH "$AFTER" pol.after.shot >/dev/null
RPUSH kmod/w1118_verify_after.sh w1118_verify_after.sh >/dev/null
AFTERV=$(REXEC "cp /home/lucy/pol.after.shot /home/lucy/pol.after 2>/dev/null; bash /home/lucy/w1118_verify_after.sh pol.after")
echo "$AFTERV" | sed 's/^/    /' | tee -a $EV/w1117_verify_shot${SHOT}.txt
#   ★行为侧的**预期是反的**：这批规则一条都没给 shell ⇒ `/data/adb` 那三格必须仍然红；绿了就是装错了东西
SR=$(A "grep -acE 'POST_adb_(touch|mkdir)_rc=0|POST_ls_adb_rc=0' $L2OUT 2>/dev/null" | tr -dc '0-9')
echo "  SHELL_STILL_RED=$([ "${SR:-0}" = 0 ] && echo '是与这批规则的承诺一致' || echo '[x] 有格翻了绿——这批里没有任何一条给 shell，说明装进去的不是这一批 ⇒ 本发读数作废')"
fi

echo "[6/6] 关窗（★重启＝把机器收回厂商策略；这次装载只在内存里，没持久化）"
A "svc power stayon false" >/dev/null
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "SHOT${SHOT}_DONE 证件：$EV/w1117_shot${SHOT}_go.log $EV/w1107_pre_shot${SHOT}.out $EV/w1117_verify_shot${SHOT}.txt $EV/w1108_load_shot${SHOT}.out $EV/w1117_pol.orig_${SHOT} $EV/w1117_pol.new_${SHOT} $EV/w1117_records_shot${SHOT}/"
