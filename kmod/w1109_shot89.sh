#!/bin/bash
# w1109_shot89.sh —— 第 89 发＝**#216-A 第一次真装载运行期策略 delta**（用户 11-02 明确点头："可以开始"）。
#   形状：开窗(交付默认形状，不装探针 ko) → **第一段只读腿 w1107 导出活动策略** → 拉回 PC → **在构建机上做离线差分**
#   → 只有"RT 语义零差 ＋ delta 恰好＋3／－0 ＋ 导出 md5＝厂商件 282a6861…"三条同时成立，才推 `pol.new` 并派
#     **第二段腿 w1108**（装载 → 再导出 → 翻回执法 → 行为格）。任何一条不过：**不推、不派、直接关窗**，这一发记"未装载"。
#   ★装载在 Permissive 段做（执法态下 `> /sys/fs/selinux/load` 被拒＝§6.445②/§6.447③），翻回执法是**单向**的，
#     所以"装载/再导出/行为格"必须在同一条腿里跑完（§关窗铁律：恢复执法排在所有 root 腿之后）。
#   ★读法（开枪前写死，四支，不许互相顶替）：
#     ①`LOAD_rc=0` 且 `AFTER_…md5 ≠ orig_md5` 且 PC 侧 `dump(pol.after)` 比 `dump(pol.orig)` **恰好多这 3 条、零删除**
#       ⇒ "delta 进了内核策略面"第一次成立（这是策略面的证人，与行为无关）；
#     ②`ENFORCE_flip_rc=0`＋执法下 `POST_touch_rc=0`/`POST_mkdir_rc=0`，且**负对照** `CTRL_setenforce0_rc≠0`、`CTRL_0777_touch_rc=0`
#       ⇒ 目标③ 的能力面真被打开且**没有把别的放开**；
#     ③`LOAD_rc≠0` ⇒ 装载被内核拒（策略没换）＝一手"我们的序列化内核不认"，是**结论不是失败**，之后不许在同 boot 重试碰运气；
#     ④`AVC_BEFORE==AVC_AFTER_PROBE`（记不到 denied）或 `verdict=未装载` ⇒ 相关格记**未测**，不许读成"没被拒"。
#   ★代价与恢复：这是一台量产机；装载只在内存里，**没有持久化**，`adb reboot` 即回到厂商策略（第 6 步必做并复核基线）。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT=${SHOT:-89}
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
gate "$L2DEV" "$M2" "装载腿"

echo "[3/6] 开窗(1 枪＝punch)＋派**第一段只读腿**（这一段结构上不可能写策略）"
LEG1ONLY=1 LEG1=$L1DEV LEG1OUT=$L1OUT LEG1MD5="$M1" I_KNOW=1 bash kmod/go.sh > $EV/w1109_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1109_shot${SHOT}_go.log | sed 's/^/  go: /'
A "cat $L1OUT 2>/dev/null" > $EV/w1107_pre_shot${SHOT}.out 2>&1
grep -aE 'BEGIN|ARM=|EXPORT_rc|HEAD16|NEG_CTRL|PRE_SYSERVER|\[x\]|END up=' $EV/w1107_pre_shot${SHOT}.out | cut -c1-200 | sed 's/^/    /'
MSYS_NO_PATHCONV=1 adb pull $DDEV/pol.orig $EV/w1109_pol.orig_${SHOT} 2>&1 | tail -1 | sed 's/^/  pull: /'
ORIG=$(md5sum $EV/w1109_pol.orig_${SHOT} 2>/dev/null | cut -d' ' -f1); OB=$(wc -c < $EV/w1109_pol.orig_${SHOT} 2>/dev/null)
echo "  本机这份 pol.orig=$OB B md5=$ORIG (厂商件应＝282a6861…/1356948 B)"
[ "$GO" = 0 ] || { echo "[x] go.sh rc=$GO ⇒ 先看日志；**不装载**"; exit 1; }

echo "[4/6] 离线差分闸：过才推 pol.new(在构建机上跑，本步不碰设备)"
RPUSH "$EV/w1109_pol.orig_${SHOT}" pol.shot${SHOT} >/dev/null; RPUSH kmod/sepolicy_delta/rules.txt delta_rules.txt >/dev/null
RPUSH kmod/w1109_verify_remote.sh w1109_verify_remote.sh >/dev/null
RExec=$(REXEC "cp /home/lucy/pol.shot${SHOT} /home/lucy/pol.orig 2>/dev/null; cp /home/lucy/w1109_verify_remote.sh /home/lucy/vr.sh 2>/dev/null; bash /home/lucy/vr.sh pol.orig delta_rules.txt")
echo "$RExec" | grep -aE '^(ORIG_MD5|RT_|DELTA_|NEW_|VERDICT|DUMP_A|BUILD)' | sed 's/^/    /' | tee $EV/w1109_verify_shot${SHOT}.txt
M1OK=$(echo "$RExec" | grep -ac '^RT_ADDED=0'); M2OK=$(echo "$RExec" | grep -ac '^RT_REMOVED=0')
M3OK=$(echo "$RExec" | grep -ac '^DELTA_ADDED=3'); M4OK=$(echo "$RExec" | grep -ac '^DELTA_REMOVED=0')
M5OK=$(echo "$RExec" | grep -ac '^VERDICT=ok'); M6OK=$(echo "$RExec" | grep -ac "^ORIG_MD5=$ORIG")
NEWM=$(echo "$RExec" | sed -n 's/^NEW_MD5=//p'); NEWB=$(echo "$RExec" | sed -n 's/^NEW_BYTES=//p')
if [ "$M1OK$M2OK$M3OK$M4OK$M5OK$M6OK" != "111111" ]; then
    echo "[x] 离线差分六把里没全过(RT_ADDED/RT_REMOVED/DELTA_ADDED/DELTA_REMOVED/VERDICT/ORIG一致)⇒ **不装载**，直接关窗；这一发记『未装载』"
    A "svc power stayon false" >/dev/null; adb reboot; adb wait-for-device; sleep 20
    echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules")"
    echo "SHOT${SHOT}_DONE verdict=未装载(离线闸没过)"; exit 1
fi
RGET new.pol "$EV/w1109_pol.new_${SHOT}" >/dev/null
NM=$(md5sum $EV/w1109_pol.new_${SHOT} | cut -d' ' -f1); NB=$(wc -c < $EV/w1109_pol.new_${SHOT})
echo "  取回 pol.new=$NB B md5=$NM 远端报 md5=$NEWM bytes=$NEWB ⇒ $( [ "$NM" = "$NEWM" ] && [ "$NB" = "$NEWB" ] && echo 两端一致 || echo 不一致)"
[ "$NM" = "$NEWM" ] && [ "$NB" = "$NEWB" ] || { echo "[x] pol.new 两端不一致 ⇒ 不装载"; exit 1; }

echo "[5/6] ★推 pol.new＋派装载腿(本项目第一次写 /sys/fs/selinux/load)"
MSYS_NO_PATHCONV=1 adb push $EV/w1109_pol.new_${SHOT} $DDEV/pol.new 2>&1 | tail -1 | sed 's/^/  /'
A "printf 'MD5=%s\nBYTES=%s\n' $NM $NB > $DDEV/expect.txt; chmod 666 $DDEV/pol.new $DDEV/expect.txt; echo 派腿前域=\$(cat /proc/self/attr/current) > $DDEV/dispatch_ctx.txt" >/dev/null
echo "  派装载腿: $(A "am force-stop com.suw.manager")$(A "am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"@sushd:$L2DEV\"" | tail -1)"
for i in $(seq 1 60); do sleep 3
    E=$(A "grep -acF 'END up=' $L2OUT 2>/dev/null" | tr -dc '0-9')
    [ "${E:-0}" -ge 1 ] && { echo "  腿跑完(第 $i 轮)"; break; }
done
A "cat $L2OUT 2>/dev/null" > $EV/w1108_load_shot${SHOT}.out 2>&1
grep -aE 'BEGIN|ARM=|NEW_md5|AVC_|PRE_|★LOAD_rc|AFTER_|ENFORCE_flip|POST_|CTRL_|\[x\]|END up=' $EV/w1108_load_shot${SHOT}.out | cut -c1-220 | sed 's/^/    /'
MSYS_NO_PATHCONV=1 adb pull $DDEV/pol.after $EV/w1109_pol.after_${SHOT} 2>&1 | tail -1 | sed 's/^/  pull: /'
RPUSH "$EV/w1109_pol.after_${SHOT}" pol.after.shot >/dev/null
AFTERV=$(REXEC "cp /home/lucy/pol.after.shot /home/lucy/pol.after 2>/dev/null; cd /home/lucy; ./w1104_host dump pol.after D.txt >/dev/null 2>&1; echo AFTER_NODES=\$(sed -n 's/^DUMP_NODES=\\([0-9]*\\).*/\\1/p' D.txt); echo AF_ADDED=\$(comm -13 <(grep -v '^DUMP_' A.txt|sort) <(grep -v '^DUMP_' D.txt|sort)|grep -ac .); echo AF_REMOVED=\$(comm -23 <(grep -v '^DUMP_' A.txt|sort) <(grep -v '^DUMP_' D.txt|sort)|grep -ac .); comm -13 <(grep -v '^DUMP_' A.txt|sort) <(grep -v '^DUMP_' D.txt|sort) | head -5 | sed 's/^/  AFADD /'")
echo "$AFTERV" | sed 's/^/    /' | tee -a $EV/w1109_verify_shot${SHOT}.txt

echo "[6/6] 关窗（★重启＝把机器收回厂商策略；这次装载只在内存里，没持久化）"
A "svc power stayon false" >/dev/null
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "SHOT${SHOT}_DONE 证件：$EV/w1109_shot${SHOT}_go.log $EV/w1107_pre_shot${SHOT}.out $EV/w1109_verify_shot${SHOT}.txt $EV/w1108_load_shot${SHOT}.out $EV/w1109_pol.{orig,new,after}_${SHOT}"
