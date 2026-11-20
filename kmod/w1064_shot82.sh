#!/bin/bash
# w1064_shot82.sh —— 第 82 发：`rt_steps=2 rt_slack_kb=64` ＝ **单变量**那一格(比第 81 发只多"喂给 reader 的那份料有没有余量")。
#   已判正的上游：第 79 发 `rd_rc=0`/`pre_len=1356948`(内核自己导出的那份拿到手了)；第 81 发(=w1045 那条臂)`rt_prs_rc=-12`
#   且形状数齐(ver=30 mls=1 nel=12683) ⇒ 幸存候选收窄到两支：(甲)reader 飘出 vmalloc 末尾撞守护页(越界读)，
#   (乙)内核态环境差(结构体宽度/字段顺序/属性位)。本发只动"料"这一维：模块自己 vmalloc(len+64K)、逐字节抄原件、
#   尾部填 0xA5，然后**从副本**解析(`fp.len` 仍＝len ⇒ 长度这一维没变，变的只有"末尾之外有没有可读物")。
#   四支读法：**判正(prs_rc=0)** ⇒ (甲)坐实，第 81 发那次复位是越界读，下一步量"飘了多少字节"；
#     **判负但形状变了(仍 prs_rc≠0 且**活到了出口**) ⇒ (甲)出局，压力给(乙)**；
#     **复位(腿没写下一行) ⇒ (甲)也在"读副本"这条路上致死，但那次致死的形状与第 81 发不同 ⇒ 仍要按 §6.493 归因，别写死**；
#     **未测(cp_same=0／abi≠82／slack 读回≠64／rd_rc≠0) ⇒ 仪器或臂不对，这一格没测，不许替它答题**。
#   ★结构上不写运行期策略：`do_load` 需要 0x4C4F4144 这把钥匙，本腿永远不传；装前装后各导一次活策略比 md5。
#   结构抄 w1046，只换腿/件/证件名(★证件名跟 SHOT 走——§6.473 的教训：写死编号会让下一发覆盖掉上一发的证据)。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT=${SHOT:-82}
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
[ -n "${MSYS_NO_PATHCONV:-}" ] && { echo "[x] 带着 MSYS_NO_PATHCONV ⇒ 拒跑(它会让离线自测假红)"; exit 3; }

echo "[1/4] 离线总闸(链内现跑)"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪(红的是闸就补前置，不是改闸)"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

LEGREPO=kmod/w1063_step2_slack_leg.sh; LEGDEV=/data/local/tmp/w1063_step2_slack_leg.sh; LEGOUT=/data/local/tmp/w1063_step2_slack.out
KOREPO=kmod/w986_polround_v5_slack.ko; KODEV=/data/local/tmp/w986_polround_v5_slack.ko
KO_MD5_WANT=2f95b23cc6cd5d55ba2939d892603618
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
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LM" I_KNOW=1 bash kmod/go.sh > $EV/w1065_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1065_shot${SHOT}_go.log | sed 's/^/  go: /'
[ "$GO" = 0 ] || { echo "[x] go.sh rc=$GO ⇒ 停，先看日志(别在没窗的情况下猜)"; exit 1; }

echo "[3/4] 腿的判据面"
A "cat $LEGOUT 2>/dev/null" > $EV/w1063_slack_shot${SHOT}.out 2>&1
UP=$(A "cut -d' ' -f1 /proc/uptime")
echo "  证件行数=$(wc -l < $EV/w1063_slack_shot${SHOT}.out) up=$UP enf=$(A getenforce) mod=$(A "grep -c '^w985_probe ' /proc/modules")"
grep -aE 'ARM=|ARGV|ko_md5|insmod_rc|MODULES_LINE|PARAM rt_steps|PARAM rt_slack_kb|PARAM rt_abi|PARAM rt_copy|PARAM rt_cp_rc|PARAM rt_cp_same|PARAM rt_sum_cp|PARAM rt_stage|PARAM rt_sym_rc|PARAM rt_slab_rc|PARAM rt_rd_rc|PARAM rt_pre_len|PARAM rt_sum_pre|PARAM rt_prs_rc|PARAM rt_nel|PARAM rt_ver|PARAM rt_mls|PARAM rt_load_rc|DMESG_w986|NP_VERDICT|rmmod_rc|POLICY_UNCHANGED|PRE_rc|POST_rc|CLEANUP|END up=|\[x\]|\[!!\]' \
  $EV/w1063_slack_shot${SHOT}.out | cut -c1-175 | sed 's/^/    /'

echo "[4/4] 关窗"
A "svc power stayon false" >/dev/null; echo "  stay_on 读回=[$(A "settings get global stay_on_while_plugged_in")]"
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "SHOT${SHOT}_DONE 证件：$EV/w1065_shot${SHOT}_go.log $EV/w1063_slack_shot${SHOT}.out"
