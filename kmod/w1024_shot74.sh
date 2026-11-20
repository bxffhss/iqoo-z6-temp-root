#!/bin/bash
# w1024_shot74.sh —— 第 74 发：极简件对照（唯一变量＝件的内容；同树、同 Makefile 形状、同样带 CFI 桩）。
# 结构抄 w996（链内现跑总闸＋绿闸新鲜度＋开枪前四把 0 枪闸＋关窗复原 stayon 并读回）。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
[ -n "${MSYS_NO_PATHCONV:-}" ] && { echo "[x] 环境带着 MSYS_NO_PATHCONV ⇒ 拒跑(会让离线自测假红)"; exit 3; }
echo "[1/4] 离线总闸 w413(链内现跑)"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }
echo "  比绿闸新的源码件=0"
LEGREPO=kmod/w1023_tiny_leg.sh; LEGDEV=/data/local/tmp/w1023_tiny_leg.sh; LEGOUT=/data/local/tmp/w1023_tiny.out
KOREPO=kmod/w1020_tiny.ko; KODEV=/data/local/tmp/w1020_tiny.ko; KO_MD5_WANT=9459387abe0affebfe80375c104e6342
echo "[2/4] 铺两件＋开枪前四把闸，然后开窗(1 枪)"
LM=$(md5sum $LEGREPO | cut -d' ' -f1)
MSYS_NO_PATHCONV=1 adb push $LEGREPO $LEGDEV 2>&1 | tail -1
MSYS_NO_PATHCONV=1 adb push $KOREPO $KODEV 2>&1 | tail -1
A "chmod 755 $LEGDEV" >/dev/null
PERM=$(A "ls -l $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}'); LBL=$(A "ls -Zd $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}')
KDEV=$(A "md5sum $KODEV 2>/dev/null" | cut -d' ' -f1)
echo "  腿权限=$PERM 标签=$LBL"; echo "  ko 两端：本机=$(md5sum $KOREPO|cut -d' ' -f1) 设备=$KDEV 登记=$KO_MD5_WANT"
[ "${PERM:3:1}" = x ] || { echo "[x] 腿没 x 位 ⇒ 不开枪"; exit 1; }
case "$LBL" in *:s0) : ;; *) echo "[x] 标签不是 plain s0($LBL) ⇒ 不开枪"; exit 1 ;; esac
[ "$KDEV" = "$KO_MD5_WANT" ] || { echo "[x] 设备上不是登记那份件 ⇒ 不开枪"; exit 1; }
SHN=$(MSYS_NO_PATHCONV=1 adb shell "/system/bin/sh -n $LEGDEV >/dev/null 2>&1 && echo SHN=OK || echo SHN=BAD" 2>&1 | tr -d '\r')
grep -q SHN=OK <<<"$SHN" || { echo "[x] 腿没过量机语法闸：$SHN"; exit 1; }
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LM" I_KNOW=1 bash kmod/go.sh > $EV/w1025_shot74_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -4 $EV/w1025_shot74_go.log | sed 's/^/  go: /'
[ "$GO" = 0 ] || { echo "[x] go.sh rc=$GO ⇒ 停，先看日志"; exit 1; }
echo "[3/4] 腿的判据面"
A "cat $LEGOUT 2>/dev/null" > $EV/w1023_tiny_shot74.out 2>&1
UP=$(A "cut -d' ' -f1 /proc/uptime"); echo "  证件行数=$(wc -l < $EV/w1023_tiny_shot74.out) up=$UP enf=$(A getenforce) tiny_in_mods=$(A "grep -c '^w1020_tiny ' /proc/modules")"
cat $EV/w1023_tiny_shot74.out | cut -c1-170 | sed 's/^/    /'
echo "[4/4] 关窗"
A "svc power stayon false" >/dev/null; echo "  stay_on 读回=[$(A "settings get global stay_on_while_plugged_in")]"
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") tiny=$(A "grep -c '^w1020_tiny ' /proc/modules")"
echo "SHOT74_DONE 证件：$EV/w1025_shot74_go.log $EV/w1023_tiny_shot74.out"
