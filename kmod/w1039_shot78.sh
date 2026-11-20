#!/bin/bash
# w1039_shot78.sh —— 第 78 发：**传参但值＝默认**(`insmod $K rt_steps=0`)，init 轨迹与第 77 发同一格(md §6.491)。
#   唯一变量＝命令行有没有那一段 `rt_steps=0`：翻面(活到 rt_stage=99)⇒「传参本身」出局，凶手在 steps≥1 那段
#   SS 代码，下一格 `rt_steps=1` 二分；当场断在 `ARGV=` 之后 ⇒ 第 72/73 发的归因落到 parse_args 那条路。
#   结构抄 w1036(第 77 发那条)，只换腿/证件名/判据词；腿里两臂证人＝`ARM=` 那行＋`PARAM rt_steps=0`。
#   为什么值得开枪：第 77 发判正之后只剩两个候选——(甲)传参本身(parse_args 早于 do_one_initcall，能解释
#   "init 一字未印却炸机")；(乙)steps≥1 才跑的 SS 代码。本发把(甲)单独摘出来判，一枪定归因。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
[ -n "${MSYS_NO_PATHCONV:-}" ] && { echo "[x] 带着 MSYS_NO_PATHCONV ⇒ 拒跑(它会让离线自测假红)"; exit 3; }

echo "[1/4] 离线总闸(链内现跑)"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪(红的是闸就补前置，不是改闸)"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

LEGREPO=kmod/w1038_steprzero_leg.sh; LEGDEV=/data/local/tmp/w1038_steprzero_leg.sh; LEGOUT=/data/local/tmp/w1038_steprzero.out
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
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LM" I_KNOW=1 bash kmod/go.sh > $EV/w1040_shot78_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1040_shot78_go.log | sed 's/^/  go: /'
[ "$GO" = 0 ] || { echo "[x] go.sh rc=$GO ⇒ 停，先看日志(别在没窗的情况下猜)"; exit 1; }

echo "[3/4] 腿的判据面"
A "cat $LEGOUT 2>/dev/null" > $EV/w1038_steprzero_shot78.out 2>&1
UP=$(A "cut -d' ' -f1 /proc/uptime")
echo "  证件行数=$(wc -l < $EV/w1038_steprzero_shot78.out) up=$UP enf=$(A getenforce) mod=$(A "grep -c '^w985_probe ' /proc/modules")"
grep -aE 'ARM=|ARGV|ko_md5|insmod_rc|MODULES_LINE|PARAM rt_steps|PARAM rt_stage|PARAM rt_sym_rc|PARAM rt_slab_rc|PARAM rt_load_rc|DMESG_w986|NP_VERDICT|rmmod_rc|POLICY_UNCHANGED|PRE_rc|POST_rc|CLEANUP|END up=|\[x\]|\[!!\]' \
  $EV/w1038_steprzero_shot78.out | cut -c1-175 | sed 's/^/    /'

echo "[4/4] 关窗"
A "svc power stayon false" >/dev/null; echo "  stay_on 读回=[$(A "settings get global stay_on_while_plugged_in")]"
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "SHOT78_DONE 证件：$EV/w1040_shot78_go.log $EV/w1038_steprzero_shot78.out"
