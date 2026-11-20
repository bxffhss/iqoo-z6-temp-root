#!/bin/bash
# w1099_shot86.sh —— 第 86 发：**只开窗、只抄 pstore**——这一发不装任何探针 ko，所以它结构上不会再制造一次"我们打崩机器"。
#   为什么值得单独开一枪(§6.512／#225)：第 84/85 两发把"死亡时刻"钉在 init 后 ≈0.1 秒，并把
#   "用户态采样这条路到此为止"证明了——因为整机冻结时所有观察方(轮询器、dmesg 跟随器)同时停。
#   剩下的事后信道只有 pstore：设备自己的 `/proc/config.gz`(世界可读)现读 `CONFIG_PSTORE_RAM=y`，
#   DT 里有 `ramoops` 节点，`/proc/mounts` 里 `/sys/fs/pstore` 已挂 ⇒ 10-02 那句"这台机没有 pstore 后端"
#   是我把一次 `total 0` 的观察写成了普遍结论(例 191①/208)。**这一发把它读回来。**
#   ★两种结果都算数、但读法不同：有记录 ⇒ 直接拿 fault 的 PC/回溯；`PS_FILES=0` ⇒ 只能说"这轮开机没有可读记录"，
#   分不清 (a)没走 panic 路径 与 (b)被中间那次 warm reboot 的 console 注册 zap 掉 ⇒ 要把二者分开，得在**死后的
#   第一个 boot** 里读(那要再排一枪)。腿里把分辨得开的形状(MOUNT_LINE/NEG_CTRL/BOOT_HIST/CFG_PSTORE)一起落盘。
#   ★安全：只读——不 insmod 探针、不写 `/sys/fs/selinux/load`、不改标签、不 rm；`do_load` 那把钥匙结构上不存在于这条链里。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT=${SHOT:-86}
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
[ -n "${MSYS_NO_PATHCONV:-}" ] && { echo "[x] 带着 MSYS_NO_PATHCONV ⇒ 拒跑(它会让离线自测假红)"; exit 3; }

echo "[1/4] 离线总闸(链内现跑)"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪(红的是闸就补前置，不是改闸)"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

LEGREPO=kmod/w1098_pstore_leg.sh; LEGDEV=/data/local/tmp/w1098_pstore_leg.sh; LEGOUT=/data/local/tmp/w1098_pstore.out
echo "[2/4] 铺腿＋四把开枪前闸"
LM=$(md5sum $LEGREPO | cut -d' ' -f1)
MSYS_NO_PATHCONV=1 adb push $LEGREPO $LEGDEV 2>&1 | tail -1
A "chmod 755 $LEGDEV" >/dev/null
PERM=$(A "ls -l $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}'); LBL=$(A "ls -Zd $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}')
echo "  腿权限=$PERM 标签=$LBL  本机登记 md5=$LM"
[ "${PERM:3:1}" = x ] || { echo "[x] 腿没 x 位 ⇒ 不开(第 69 发：root 也要 x 位，否则 exit=126)"; exit 1; }
case "$LBL" in *:s0) : ;; *) echo "[x] 标签不是 plain s0 ⇒ 不开(带类别挡 execute＝#114)"; exit 1 ;; esac
DEVMD5=$(A "md5sum $LEGDEV 2>/dev/null" | cut -d' ' -f1)
[ "$DEVMD5" = "$LM" ] || { echo "[x] 设备上不是本机这支腿(本机 $LM / 设备 $DEVMD5)⇒ 不开"; exit 1; }
SHN=$(MSYS_NO_PATHCONV=1 adb shell "/system/bin/sh -n $LEGDEV >/dev/null 2>&1 && echo SHN=OK || echo SHN=BAD" 2>&1 | tr -d '\r')
grep -q SHN=OK <<<"$SHN" || { echo "[x] 腿没过设备语法闸：$SHN"; exit 1; }

echo "[3/4] 开窗(1 枪＝punch；本发不装探针 ko)"
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LM" I_KNOW=1 bash kmod/go.sh > $EV/w1099_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -4 $EV/w1099_shot${SHOT}_go.log | sed 's/^/  go: /'
[ "$GO" = 0 ] || { echo "[x] go.sh rc=$GO ⇒ 先看日志(别在没窗的情况下猜)"; }

echo "[4/4] 收 pstore 的三面(腿的判据面＋抄下来的每条记录原件)"
A "cat $LEGOUT 2>/dev/null" > $EV/w1098_pstore_shot${SHOT}.out 2>&1
rm -rf $EV/w1098_records_shot${SHOT} 2>/dev/null
MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w1098_pstore $EV/w1098_records_shot${SHOT} 2>&1 | tail -1
echo "  证件行数=$(wc -l < $EV/w1098_pstore_shot${SHOT}.out) 抄回来的文件数=$(ls $EV/w1098_records_shot${SHOT} 2>/dev/null | wc -l) up=$(A "cut -d' ' -f1 /proc/uptime") enf=$(A getenforce) mod=$(A "grep -c '^kernelsu ' /proc/modules")"
echo "  ---- 腿的原始读数(派生判断留给主机侧)----"
grep -aE 'BEGIN|ARM=|BOOTREASON|BOOT_HIST|MOUNT_|CFG_rc|CFG_PSTORE|DMESG_|NEG_CTRL|FILE |PS_FILES|ENFORCE_NOW|MODULES_|RESIDUE_|\[x\]|END up=' \
  $EV/w1098_pstore_shot${SHOT}.out | cut -c1-300 | sed 's/^/    /'
echo "  ---- 抄回来的东西的形状(名字／字节数／md5；内容由人读，不在这里下结论)----"
ls -l $EV/w1098_records_shot${SHOT} 2>/dev/null | tail -12 | sed 's/^/    /'
md5sum $EV/w1098_records_shot${SHOT}/*ramoops* 2>/dev/null | sed 's/^/    /' || echo "    (没有 ramoops 件可算 md5)"

echo "[5/5] 关窗"
A "svc power stayon false" >/dev/null; echo "  stay_on 读回=[$(A "settings get global stay_on_while_plugged_in")]"
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules")"
echo "SHOT${SHOT}_DONE 证件：$EV/w1099_shot${SHOT}_go.log $EV/w1098_pstore_shot${SHOT}.out $EV/w1098_records_shot${SHOT}/"
