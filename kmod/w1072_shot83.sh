#!/bin/bash
# w1072_shot83.sh —— 第 83 发：**第 82 发那一格原样重打，唯一变化＝"证人搬到复位之后还读得到的地方"**(腿里带后台轮询器)。
#   为什么值得再花一发(§6.503)：第 82 发不是"测了但红"，而是**根本没测到**——判据全靠 `/sys/module/*/parameters`，
#   模块一死口就没了 ⇒ `rt_abi`/`rt_copy`/`rt_cp_same` 一个都没读回来 ⇒ "64 KB 余量真被吃到过"没有证人。
#   本版按设备自己那份 `kernel/module.c`(4099 行 `mod_sysfs_setup` 排在 4115 行 `do_init_module` **之前**)起一个
#   后台轮询子壳，每 0.2 秒把八支关键参数**逐字**抄进 `$P`(另一个文件＝一个文件一个写者)，复位也带得走。
#   开枪前四把闸照旧(腿 x 位／plain s0 标签／设备上 ko md5＝登记／设备 mksh `sh -n`)＋**新增一把**：
#   ★`w1071_poll_mech_dev.sh` 必须 `MECH_RC=0`(先证明这台机的 `sleep 0.2` 真延时、内建 `read` 真取到值，再拿轮询器当证人)。
#   读法四支(全看 `$P`，不看 `$L` 有没有下一行)：①出现 `copy=1 cpsame=1` ⇒ 副本确实被吃过 ⇒ 若仍复位，(甲)里"只飘一点点"那种不成立；
#   ②只到 `stage=2/21` 从没 `copy=1` ⇒ 死在搬副本之前 ⇒ (甲)仍未测，凶器更靠前；③`$P` 一行 TICK 都没有 ⇒ 我那条源码推断被否证，记**仪器否证**；
#   ④`abi≠82` ⇒ 装上去的不是这一版件 ⇒ 全格未测。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT=${SHOT:-83}
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
[ -n "${MSYS_NO_PATHCONV:-}" ] && { echo "[x] 带着 MSYS_NO_PATHCONV ⇒ 拒跑(它会让离线自测假红)"; exit 3; }

echo "[1/5] 离线总闸(链内现跑)"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪(红的是闸就补前置，不是改闸)"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

LEGREPO=kmod/w1069_step2_pol_leg.sh; LEGDEV=/data/local/tmp/w1069_step2_pol_leg.sh; LEGOUT=/data/local/tmp/w1069_step2_pol.out
POUTDEV=/data/local/tmp/w1069_pol.txt; PERRDEV=/data/local/tmp/w1069_pol.err
KOREPO=kmod/w986_polround_v5_slack.ko; KODEV=/data/local/tmp/w986_polround_v5_slack.ko
KO_MD5_WANT=2f95b23cc6cd5d55ba2939d892603618
echo "[2/5] ★先跑 0 枪的轮询器机制预检(不装模块、不碰执法；它红了就不开枪)"
MSYS_NO_PATHCONV=1 adb push kmod/w1071_poll_mech_dev.sh /data/local/tmp/w1071_poll_mech_dev.sh 2>&1 | tail -1
A "chmod 755 /data/local/tmp/w1071_poll_mech_dev.sh" >/dev/null
#   ★这一把闸第一次跑就**正确地拒了枪**，但拒因是我这条链的 bug：预检件把结论写进**设备上的文件** `$P`，
#     我却去 grep 它的 stdout ⇒ 抓到的是空的 stderr ⇒ 判红。规矩没错(读不到＝不许当通过)，错的是我指的面对。
A "rm -rf /data/local/tmp/w1071_mech; /system/bin/sh /data/local/tmp/w1071_poll_mech_dev.sh; echo MECH_RUN_RC=\$?; cat /data/local/tmp/w1071_mech/tick.txt" > $EV/w1071_mech_shot${SHOT}.txt 2>&1
grep -aE 'MECH|SLEEP_PROOF' $EV/w1071_mech_shot${SHOT}.txt | cut -c1-170 | sed 's/^/      /'
grep -aq 'MECH_RC=0' $EV/w1071_mech_shot${SHOT}.txt || { echo "[x] 轮询器机制预检没判 0 ⇒ 不开枪(证人通道不可用)"; exit 1; }
grep -aq 'MECH_RUN_RC=0' $EV/w1071_mech_shot${SHOT}.txt || { echo "[x] 预检件自己退出码不是 0 ⇒ 不开枪"; exit 1; }

echo "[3/5] 铺两件＋四把开枪前闸，然后开窗(1 枪)"
LM=$(md5sum $LEGREPO | cut -d' ' -f1)
MSYS_NO_PATHCONV=1 adb push $LEGREPO $LEGDEV 2>&1 | tail -1
MSYS_NO_PATHCONV=1 adb push $KOREPO $KODEV 2>&1 | tail -1
A "chmod 755 $LEGDEV" >/dev/null
PERM=$(A "ls -l $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}'); LBL=$(A "ls -Zd $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}')
KDEV=$(A "md5sum $KODEV 2>/dev/null" | cut -d' ' -f1)
echo "  腿权限=$PERM 标签=$LBL  ko设备=$KDEV 登记=$KO_MD5_WANT"
[ "${PERM:3:1}" = x ] || { echo "[x] 腿没 x 位 ⇒ 不开枪"; exit 1; }
case "$LBL" in *:s0) : ;; *) echo "[x] 标签不是 plain s0 ⇒ 不开枪(带类别挡 execute＝#114)"; exit 1 ;; esac
[ "$KDEV" = "$KO_MD5_WANT" ] || { echo "[x] 设备上不是登记那份件 ⇒ 不开枪"; exit 1; }
SHN=$(MSYS_NO_PATHCONV=1 adb shell "/system/bin/sh -n $LEGDEV >/dev/null 2>&1 && echo SHN=OK || echo SHN=BAD" 2>&1 | tr -d '\r')
grep -q SHN=OK <<<"$SHN" || { echo "[x] 腿没过设备语法闸：$SHN"; exit 1; }
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LM" I_KNOW=1 bash kmod/go.sh > $EV/w1073_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1073_shot${SHOT}_go.log | sed 's/^/  go: /'
[ "$GO" = 0 ] || { echo "[x] go.sh rc=$GO ⇒ 停，先看日志(别在没窗的情况下猜)"; exit 1; }

echo "[4/5] 腿的判据面＋★轮询器那份(复位后还读得到的证人)"
A "cat $LEGOUT 2>/dev/null" > $EV/w1069_pol_shot${SHOT}.out 2>&1
A "cat $POUTDEV 2>/dev/null" > $EV/w1069_tick_shot${SHOT}.txt 2>&1
A "cat $PERRDEV 2>/dev/null" > $EV/w1069_perr_shot${SHOT}.txt 2>&1
UP=$(A "cut -d' ' -f1 /proc/uptime")
echo "  证件行数=$(wc -l < $EV/w1069_pol_shot${SHOT}.out) 轮询行数=$(wc -l < $EV/w1069_tick_shot${SHOT}.txt) 轮询stderr行数=$(wc -l < $EV/w1069_perr_shot${SHOT}.txt) up=$UP enf=$(A getenforce) mod=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "  ---- 轮询器读数(原始 TICK 逐行印出，派生判断留给主机侧)----"
grep -aE '^TICK |^POL_' $EV/w1069_tick_shot${SHOT}.txt | cut -c1-200 | sed 's/^/    /'
echo "  ---- 腿自己的判据面 ----"
grep -aE 'ARM=|ARGV|SLEEP_PROOF|POLL=|POLL_STOP|POLL_LAST|POLL_BYTES|ko_md5|insmod_rc|MODULES_LINE|PARAM rt_steps|PARAM rt_slack_kb|PARAM rt_abi|PARAM rt_copy|PARAM rt_cp_rc|PARAM rt_cp_same|PARAM rt_sum_cp|PARAM rt_stage|PARAM rt_rd_rc|PARAM rt_prs_rc|PARAM rt_pre_len|PARAM rt_sum_pre|PARAM rt_nel|PARAM rt_ver|PARAM rt_mls|DMESG_w986|NP_VERDICT|rmmod_rc|POLICY_UNCHANGED|PRE_rc|POST_rc|CLEANUP|END up=|\[x\]|\[!!\]' \
  $EV/w1069_pol_shot${SHOT}.out | cut -c1-175 | sed 's/^/    /'

echo "[5/5] 关窗"
A "svc power stayon false" >/dev/null; echo "  stay_on 读回=[$(A "settings get global stay_on_while_plugged_in")]"
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "SHOT${SHOT}_DONE 证件：$EV/w1073_shot${SHOT}_go.log $EV/w1069_pol_shot${SHOT}.out $EV/w1069_tick_shot${SHOT}.txt $EV/w1071_mech_shot${SHOT}.txt"
