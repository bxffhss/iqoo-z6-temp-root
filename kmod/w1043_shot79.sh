#!/bin/bash
# w1043_shot79.sh —— 第 79 发：`rt_steps=1` ⇒ 在第 78 发那一格之上**只多加一次 `security_read_policy` 调用**(md §6.492)。
#   唯一变量＝steps 从 0 到 1。四支读法：**复位**⇒"在模块里调内核那个导出函数"这件事本身出局 ⇒ #216-B 换数据入口
#   (用户态把 `/sys/fs/selinux/policy` 的字节喂进模块)；**判正且 rd_rc=0/pre_len=1356948**⇒这一步走得通，凶手收窄到
#   "我们那份 reader/writer"(stage 3/4)⇒下一格再加一步；**判正但 rd_rc≠0**⇒按 rc 归因(机器活着＝不是崩，是返回错误)。
#   结构抄 w1039(第 78 发那条)，只换腿/证件名；腿里三行证人＝`ARM=`＋`WANT_STEPS=1`＋`ARGV=… rt_steps=1`。
#   为什么值得开枪：第 76/77/78 发已经把"装载机器学""空 init""传参本身"逐层摘干净，(乙)是唯一幸存候选；
#   而(乙)里 stage2 与 stage3/4 的失败模式完全不同(前者要换数据入口，后者只是我们那份移植件的 bug)。
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

LEGREPO=kmod/w1042_step1_leg.sh; LEGDEV=/data/local/tmp/w1042_step1_leg.sh; LEGOUT=/data/local/tmp/w1042_step1.out
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
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LM" I_KNOW=1 bash kmod/go.sh > $EV/w1044_shot79_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1044_shot79_go.log | sed 's/^/  go: /'
[ "$GO" = 0 ] || { echo "[x] go.sh rc=$GO ⇒ 停，先看日志(别在没窗的情况下猜)"; exit 1; }

echo "[3/4] 腿的判据面"
A "cat $LEGOUT 2>/dev/null" > $EV/w1042_step1_shot79.out 2>&1
UP=$(A "cut -d' ' -f1 /proc/uptime")
echo "  证件行数=$(wc -l < $EV/w1042_step1_shot79.out) up=$UP enf=$(A getenforce) mod=$(A "grep -c '^w985_probe ' /proc/modules")"
grep -aE 'ARM=|ARGV|ko_md5|insmod_rc|MODULES_LINE|PARAM rt_steps|PARAM rt_stage|PARAM rt_sym_rc|PARAM rt_slab_rc|PARAM rt_rd_rc|PARAM rt_pre_len|PARAM rt_sum_pre|PARAM rt_load_rc|DMESG_w986|NP_VERDICT|rmmod_rc|POLICY_UNCHANGED|PRE_rc|POST_rc|CLEANUP|END up=|\[x\]|\[!!\]' \
  $EV/w1042_step1_shot79.out | cut -c1-175 | sed 's/^/    /'

echo "[4/4] 关窗"
A "svc power stayon false" >/dev/null; echo "  stay_on 读回=[$(A "settings get global stay_on_while_plugged_in")]"
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "SHOT79_DONE 证件：$EV/w1044_shot79_go.log $EV/w1042_step1_shot79.out"
