#!/bin/bash
# w1094_shot85.sh —— 第 85 发：**第 84 发那一格重打，唯一变化＝把"段过渡的记录"搬进被测内部＋轮询器心跳换到时间轴**(§6.510／例 215)。
#   为什么值得再花一发：第 84 发把通道打通了(现读 `abi=84`、并在 `init` 运行期间读到 `rt_stage=1`、证人活过了硬复位)，
#   但正题那格("死在读循环哪一段")仍＝未测——"三行 CHG 之后没有第四行"同时兼容 (甲)卡在 stage 1 与 (乙)采样器自己停了，
#   因为它的"活着"只能靠 `HB`(每 2 万次读)证，而"次数→秒"的换算率由被测状态决定 ⇒ **`HB` 缺席在两档速率下都不信息**。
#   ⇒ 本版两处改动都冲着这个分母：①件里加 48 项环 `rt_hist`＋一个把整环印成**一行**的快照读点 `/proc/w986_hist`
#     ⇒ 快过渡不再会被采样跳过；②轮询器**每行自带 `I=`(读了多少轮)＋`up=`＋`bytes=`**，落盘条件＝"值变了 **或** 走过一整秒"
#     ⇒ 分母由产物自己现印，不再需要那条换算率未知的次数轴心跳。
#   开枪前五把闸照旧(腿 x 位／plain s0 标签／设备上 ko md5＝登记／设备 mksh `sh -n`／`w1071` 的 `MECH_RC=0`)。
#   ★这一发**不是**在测 §6.507/§6.508 已经拿源码否证掉的那两族；它测的是"读循环走到第几段/第几条"。读法(全看 `$P`)：
#   ①环里出现 `…:N:…` 且末项 N≥1 ⇒ **第一次拿到带内的死亡段**(N 对着 `w1085` 那张补丁表读；6 在这份树里留空)；
#   ②末项停在 `stage=2`/`21` 而从未进 `sub` ⇒ 死在搬副本那一步前后，SS 读循环根本没进；
#   ③`$P` 里一行 `SAMP` 都没有而 `ko_md5`/`ARGV` 都在 ⇒ **`/proc` 那个口在 init 期间读不到** ⇒ 这是对第 84 发
#     "通道成立"那条判正的**再否定一次**(注意：那次证的是参数面 sysfs，这次是 proc 口——两个面是两个独立结论)，落账不许圆场；
#   ④`bytes=0`/`hist=NA` ⇒ 口还没长出来；行里 `TORN=1` ⇒ 那行是撕裂读，只看形状不当位置；
#   ⑤`abi≠85` ⇒ 装上去的不是这一版件 ⇒ 全格未测。
#   ★开枪后要做的第一件派生计算：拿相邻两行的 `ΔI/Δup` 现算"这一档每轮多少毫秒"。**没有这个数，任何"没看到"都不许当否据。**
#   ★史账一句：上一轮的 `kmod/w1088_shot84.sh` 标题行写的是"第 83 发"＝抄写残留；那份文件的身份以 `SHOT=84` 与登记值 `ad0d97d8…` 为准(不改它，改了就动了"真跑过的那一份")。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT=${SHOT:-85}
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
[ -n "${MSYS_NO_PATHCONV:-}" ] && { echo "[x] 带着 MSYS_NO_PATHCONV ⇒ 拒跑(它会让离线自测假红)"; exit 3; }

echo "[1/5] 离线总闸(链内现跑)"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪(红的是闸就补前置，不是改闸)"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

LEGREPO=kmod/w1093_hist_pol_leg.sh; LEGDEV=/data/local/tmp/w1093_hist_pol_leg.sh; LEGOUT=/data/local/tmp/w1093_hist_pol.out
POUTDEV=/data/local/tmp/w1093_hist.txt; PERRDEV=/data/local/tmp/w1093_hist.err
KOREPO=kmod/w986_polround_v7_substep.ko; KODEV=/data/local/tmp/w986_polround_v7_substep.ko
KO_MD5_WANT=20b15b11e43bd3b057d69d4b847c041a
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
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LM" I_KNOW=1 bash kmod/go.sh > $EV/w1089_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1089_shot${SHOT}_go.log | sed 's/^/  go: /'
[ "$GO" = 0 ] || { echo "[x] go.sh rc=$GO ⇒ 停，先看日志(别在没窗的情况下猜)"; exit 1; }

echo "[4/5] 腿的判据面＋★轮询器那份(复位后还读得到的证人——这次里面装的是**整条轨迹**)"
A "cat $LEGOUT 2>/dev/null" > $EV/w1093_hist_shot${SHOT}.out 2>&1
A "cat $POUTDEV 2>/dev/null" > $EV/w1093_samp_shot${SHOT}.txt 2>&1
A "cat $PERRDEV 2>/dev/null" > $EV/w1093_serr_shot${SHOT}.txt 2>&1
UP=$(A "cut -d' ' -f1 /proc/uptime")
echo "  证件行数=$(wc -l < $EV/w1093_hist_shot${SHOT}.out) 快照行数=$(wc -l < $EV/w1093_samp_shot${SHOT}.txt) 轮询stderr行数=$(wc -l < $EV/w1093_serr_shot${SHOT}.txt) up=$UP enf=$(A getenforce) mod=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "  ---- 轮询器读数(原始 SAMP 逐行印出；每行自带 I/up/bytes＝**分母由产物现印**，派生判断留给主机侧)----"
grep -aE '^SAMP |^POL_' $EV/w1093_samp_shot${SHOT}.txt | cut -c1-300 | sed 's/^/    /'
echo "  ---- 分母(现算：相邻两行的 ΔI/Δup ⇒ 这一档每轮多少毫秒。**没有这个数，任何「没看到」都不许当否据**；整行在证据文件里)----"
awk '/^SAMP /{ I=$2+0; u=$3; sub(/^up=/,"",u); U=u+0;
     if(have){ di=I-pI; du=U-pU;
       if(di>0) printf("    RATE I %d→%d ΔI=%d Δup=%.2f ⇒ %.3f ms/轮\n", pI, I, di, du, 1000*du/di);
       else printf("    RATE I %d→%d ΔI=0 ⇒ 两行同一轮，分母不可用\n", pI, I) }
     pI=I; pU=U; have=1 }' $EV/w1093_samp_shot${SHOT}.txt | sed 's/^/    /'
echo "  ---- 环里最长那一行的段号轨迹(只印 hist= 之后的部分，给人眼读)----"
awk '/^SAMP /{ p=index($0,"hist="); if(p>0){ s=substr($0,p+5); if(length(s)>ml){ ml=length(s); last=s; n=$2 } } }
     END{ if(ml>0) printf("    最长一行 bytes=%d 来自 I=%d\n    %s\n", ml, n, last) }' $EV/w1093_samp_shot${SHOT}.txt | cut -c1-400 | sed 's/^/    /'
echo "  ---- 腿自己的判据面 ----"
grep -aE 'ARM=|ARGV|SLEEP_PROOF|POLL=|POLL_STOP|POLL_LAST|POLL_BYTES|ko_md5|insmod_rc|MODULES_LINE|PARAM rt_steps|PARAM rt_slack_kb|PARAM rt_abi|PARAM rt_sub|PARAM rt_idx|PARAM rt_idx2|PARAM rt_seq|PARAM rt_hist_next|PARAM rt_hist_proc|PARAM rt_copy|PARAM rt_cp_rc|PARAM rt_cp_same|PARAM rt_sum_cp|PARAM rt_stage|PARAM rt_rd_rc|PARAM rt_prs_rc|PARAM rt_pre_len|PARAM rt_sum_pre|PARAM rt_nel|PARAM rt_ver|PARAM rt_mls|DMESG_w986|NP_VERDICT|rmmod_rc|POLICY_UNCHANGED|PRE_rc|POST_rc|CLEANUP|END up=|\[x\]|\[!!\]' \
  $EV/w1093_hist_shot${SHOT}.out | cut -c1-175 | sed 's/^/    /'

echo "[5/5] 关窗"
A "svc power stayon false" >/dev/null; echo "  stay_on 读回=[$(A "settings get global stay_on_while_plugged_in")]"
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "SHOT${SHOT}_DONE 证件：$EV/w1089_shot${SHOT}_go.log $EV/w1093_hist_shot${SHOT}.out $EV/w1093_samp_shot${SHOT}.txt $EV/w1093_serr_shot${SHOT}.txt $EV/w1071_mech_shot${SHOT}.txt"
