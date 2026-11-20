#!/bin/bash
# w1046_shot80.sh —— `rt_steps=2` 那一格的链(第 80 发＝空枪已花；默认按第 81 发跑)：`rt_steps=2` ⇒ 在第 79 发那一格之上**只多加一步**：我们那份 `policydb_read` 解析它(md §6.493)。
#   上游已判正：第 79 发 `rd_rc=0`/`pre_len=1356948`，且离线重算 FNV-1a64 与用户态那份**完全相同**(同一份料)。
#   ⇒ 幸存候选只剩"我们编进模块的那份 SS 代码"。本腿放到 stage3 就收(源码里 `rt_steps<3` 的早退出口)：
#     **不写、不复读、不建 /proc、不装载**。
#   四支读法：**复位**⇒凶手＝我们那份 reader 在内核态解析这份厂商策略(下一步只能改形状：主机侧解析／或"内核只导出、我们只装载")；
#     **判正(prs_rc=0/nel>0)**⇒解析得动，凶手收窄到 stage4 那份 writer ⇒ 下一格 rt_steps=3；
#     **判正但 prs_rc≠0**⇒**我的调用序列失败**，抄 ver/mls/nel 离线对，不写成"此路不通"(§6.461 那次 rc=−1 真因只是少一步 set_typevers)；
#     **未测(rd_rc≠0)**⇒上游就断了，这一格根本没被问到。
#   结构抄 w1043，只换腿/证件名。腿里四行证人＝`ARM=`＋`WANT_STEPS=2`＋`ARGV=… rt_steps=2`＋`PARAM rt_steps=2`。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
# ★证件名跟 SHOT 走(§6.473 的教训：写死编号会让下一发**覆盖掉上一发的证据**——
#   第 80 发就是空枪，那份证件必须留得住)。默认 81；重打就 `SHOT=82 bash …`。
SHOT=${SHOT:-81}
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
[ -n "${MSYS_NO_PATHCONV:-}" ] && { echo "[x] 带着 MSYS_NO_PATHCONV ⇒ 拒跑(它会让离线自测假红)"; exit 3; }

echo "[1/4] 离线总闸(链内现跑)"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪(红的是闸就补前置，不是改闸)"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

LEGREPO=kmod/w1045_step2_leg.sh; LEGDEV=/data/local/tmp/w1045_step2_leg.sh; LEGOUT=/data/local/tmp/w1045_step2.out
KOREPO=kmod/w986_polround_v4_cfi.ko; KODEV=/data/local/tmp/w986_polround_v4_cfi.ko
KO_MD5_WANT=f0e8ee245b231d827665b7aed9f30db7
echo "[2/4] 铺两件＋四把开枪前闸，然后开窗(1 枪)"
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
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LM" I_KNOW=1 bash kmod/go.sh > $EV/w1048_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1048_shot${SHOT}_go.log | sed 's/^/  go: /'
[ "$GO" = 0 ] || { echo "[x] go.sh rc=$GO ⇒ 停，先看日志(别在没窗的情况下猜)"; exit 1; }

echo "[3/4] 腿的判据面"
A "cat $LEGOUT 2>/dev/null" > $EV/w1045_step2_shot${SHOT}.out 2>&1
UP=$(A "cut -d' ' -f1 /proc/uptime")
echo "  证件行数=$(wc -l < $EV/w1045_step2_shot${SHOT}.out) up=$UP enf=$(A getenforce) mod=$(A "grep -c '^w985_probe ' /proc/modules")"
grep -aE 'ARM=|ARGV|ko_md5|insmod_rc|MODULES_LINE|PARAM rt_steps|PARAM rt_stage|PARAM rt_sym_rc|PARAM rt_slab_rc|PARAM rt_rd_rc|PARAM rt_pre_len|PARAM rt_sum_pre|PARAM rt_prs_rc|PARAM rt_nel|PARAM rt_ver|PARAM rt_mls|PARAM rt_load_rc|DMESG_w986|NP_VERDICT|rmmod_rc|POLICY_UNCHANGED|PRE_rc|POST_rc|CLEANUP|END up=|\[x\]|\[!!\]' \
  $EV/w1045_step2_shot${SHOT}.out | cut -c1-175 | sed 's/^/    /'

echo "[4/4] 关窗"
A "svc power stayon false" >/dev/null; echo "  stay_on 读回=[$(A "settings get global stay_on_while_plugged_in")]"
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "SHOT${SHOT}_DONE 证件：$EV/w1048_shot${SHOT}_go.log $EV/w1045_step2_shot${SHOT}.out"
