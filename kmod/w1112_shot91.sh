#!/bin/bash
# w1112_shot91.sh —— 第 91 发＝**运行期策略 delta 的第一次"真装载尝试"**（v2 形状；装载动作＝用户 11-02 已点头那一格）。
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
SHOT=${SHOT:-91}
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
S=$(A "cd /data/local/tmp; dd if=/dev/zero of=.w1112_z bs=1356984 count=1 2>&1 | tr '\n' '|'; rm -f .w1112_z" | tr -d '\r')
echo "  设备 dd 形状现测=$S"
grep -q '1+0 records out' <<<"$S" || { echo "[x] 设备 dd 没印『1+0 records out』⇒ 装载腿的形状闸词不对，先修词再开枪"; exit 1; }

echo "[3/6] 开窗(1 枪＝punch)＋派**第一段只读腿**(结构上不可能写策略)"
LEG1ONLY=1 LEG1=$L1DEV LEG1OUT=$L1OUT LEG1MD5="$M1" I_KNOW=1 bash kmod/go.sh > $EV/w1112_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1112_shot${SHOT}_go.log | sed 's/^/  go: /'
A "cat $L1OUT 2>/dev/null" > $EV/w1107_pre_shot${SHOT}.out 2>&1
grep -aE 'BEGIN|ARM=|EXPORT_rc|HEAD16|NEG_CTRL|PRE_SYSERVER|\[x\]|END up=' $EV/w1107_pre_shot${SHOT}.out | cut -c1-200 | sed 's/^/    /'
MSYS_NO_PATHCONV=1 adb pull $DDEV/pol.orig $EV/w1112_pol.orig_${SHOT} 2>&1 | tail -1 | sed 's/^/  pull: /'
ORIG=$(md5sum $EV/w1112_pol.orig_${SHOT} 2>/dev/null | cut -d' ' -f1); OB=$(wc -c < $EV/w1112_pol.orig_${SHOT} 2>/dev/null)
echo "  本机这份 pol.orig=$OB B md5=$ORIG (厂商件应＝282a6861…/1356948 B)"
[ "$GO" = 0 ] || { echo "[x] go.sh rc=$GO ⇒ 先看日志；**不装载**"; exit 1; }

echo "[4/6] 离线差分闸：六把全过才推 pol.new(在构建机上跑，本步不碰设备)"
RPUSH "$EV/w1112_pol.orig_${SHOT}" pol.shot$SHOT >/dev/null; RPUSH kmod/sepolicy_delta/rules.txt delta_rules.txt >/dev/null
RPUSH kmod/w1109_verify_remote.sh w1109_verify_remote.sh >/dev/null
RExec=$(REXEC "cp /home/lucy/pol.shot$SHOT /home/lucy/pol.orig 2>/dev/null; cp /home/lucy/w1109_verify_remote.sh /home/lucy/vr.sh 2>/dev/null; bash /home/lucy/vr.sh pol.orig delta_rules.txt")
echo "$RExec" | grep -aE '^(ORIG_MD5|RT_|DELTA_|NEW_|NODES_|VERDICT|DUMP_A|TRAILER)' | sed 's/^/    /' | tee $EV/w1112_verify_shot${SHOT}.txt
M1OK=$(echo "$RExec" | grep -ac '^RT_ADDED=0'); M2OK=$(echo "$RExec" | grep -ac '^RT_REMOVED=0')
M3OK=$(echo "$RExec" | grep -ac '^DELTA_ADDED=3'); M4OK=$(echo "$RExec" | grep -ac '^DELTA_REMOVED=0')
M5OK=$(echo "$RExec" | grep -ac '^VERDICT=ok'); M6OK=$(echo "$RExec" | grep -ac "^ORIG_MD5=$ORIG")
NEWM=$(echo "$RExec" | sed -n 's/^NEW_MD5=//p'); NEWB=$(echo "$RExec" | sed -n 's/^NEW_BYTES=//p')
if [ "$M1OK$M2OK$M3OK$M4OK$M5OK$M6OK" != "111111" ]; then
    echo "[x] 离线差分六把没全过(RT±/DELTA±/VERDICT/ORIG 一致) ⇒ **不装载**，直接关窗；这一发记『未装载』"
    A "svc power stayon false" >/dev/null; adb reboot; adb wait-for-device; sleep 20
    echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules")"
    echo "SHOT${SHOT}_DONE verdict=未装载(离线闸没过)"; exit 1
fi
RGET new.pol "$EV/w1112_pol.new_${SHOT}" >/dev/null
NM=$(md5sum $EV/w1112_pol.new_${SHOT} | cut -d' ' -f1); NB=$(wc -c < $EV/w1112_pol.new_${SHOT})
echo "  取回 pol.new=$NB B md5=$NM 远端报 md5=$NEWM bytes=$NEWB ⇒ $( [ "$NM" = "$NEWM" ] && [ "$NB" = "$NEWB" ] && echo 两端一致 || echo 不一致)"
[ "$NM" = "$NEWM" ] && [ "$NB" = "$NEWB" ] || { echo "[x] pol.new 两端不一致 ⇒ 不装载"; exit 1; }

echo "[5/6] ★推 pol.new＋派装载腿 v2(干跑证形状→装 pol.orig 当对照→装 pol.new)"
MSYS_NO_PATHCONV=1 adb push $EV/w1112_pol.new_${SHOT} $DDEV/pol.new 2>&1 | tail -1 | sed 's/^/  /'
A "printf 'MD5=%s\nBYTES=%s\n' $NM $NB > $DDEV/expect.txt; chmod 666 $DDEV/pol.new $DDEV/expect.txt; echo 派腿前域=\$(cat /proc/self/attr/current) > $DDEV/dispatch_ctx.txt" >/dev/null
echo "  派装载腿: $(A "am force-stop com.suw.manager")$(A "am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"@sushd:$L2DEV\"" | tail -1)"
for i in $(seq 1 60); do sleep 3
    E=$(A "grep -acF 'END up=' $L2OUT 2>/dev/null" | tr -dc '0-9')
    [ "${E:-0}" -ge 1 ] && { echo "  腿跑完(第 $i 轮)"; break; }
done
A "cat $L2OUT 2>/dev/null" > $EV/w1108_load_shot${SHOT}.out 2>&1
grep -aE 'BEGIN|ARM=|NEW_md5|ORIG_md5|AVC_|PRE_|DRY_|★CTRL_LOAD|★DELTA_LOAD|AFTER_|ENFORCE_flip|POST_|CTRL_|\[x\]|COUNTS|END up=' $EV/w1108_load_shot${SHOT}.out | cut -c1-240 | sed 's/^/    /'
#   ★pull 清单由**腿自己的写点**推出来，不手数(§6.516 那条)：整目录拉回，缺哪个文件当场看得见
MSYS_NO_PATHCONV=1 adb pull $DDEV $EV/w1112_records_shot${SHOT} 2>&1 | tail -1 | sed 's/^/  pull: /'
AFTER=$EV/w1112_records_shot${SHOT}/pol.after
[ -f "$AFTER" ] || { echo "  [!] pol.after 不在(=$AFTER) ⇒ 装后那一侧记未导出，不许拿 AF_* 的 0 当结论"; }
if [ -f "$AFTER" ]; then
RPUSH "$AFTER" pol.after.shot >/dev/null
AFTERV=$(REXEC "cp /home/lucy/pol.after.shot /home/lucy/pol.after 2>/dev/null; cd /home/lucy; ./w1104_host dump pol.after D.txt >/dev/null 2>&1; echo AFTER_NODES=\$(sed -n 's/^DUMP_NODES=\\([0-9]*\\).*/\\1/p' D.txt); R() { grep -v '^DUMP_' \$1 | sort; }; echo AF_ADDED=\$(comm -13 <(R A.txt) <(R D.txt)|grep -ac .); echo AF_REMOVED=\$(comm -23 <(R A.txt) <(R D.txt)|grep -ac .); comm -13 <(R A.txt) <(R D.txt) | head -5 | sed 's/^/  AFADD /'")
echo "$AFTERV" | sed 's/^/    /' | tee -a $EV/w1112_verify_shot${SHOT}.txt
fi

echo "[6/6] 关窗（★重启＝把机器收回厂商策略；这次装载只在内存里，没持久化）"
A "svc power stayon false" >/dev/null
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "SHOT${SHOT}_DONE 证件：$EV/w1112_shot${SHOT}_go.log $EV/w1107_pre_shot${SHOT}.out $EV/w1112_verify_shot${SHOT}.txt $EV/w1108_load_shot${SHOT}.out $EV/w1112_pol.orig_${SHOT} $EV/w1112_pol.new_${SHOT} $EV/w1112_records_shot${SHOT}/"
