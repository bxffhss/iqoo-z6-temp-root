#!/bin/bash
# w172_run.sh —— #73 第二步的一条命令：在 **rc62** 的窗口里跑"前测→写回(c=4)→后测"。
#   前提：窗口是用 rc62 起的 ——  KO=kmod/kernelsu_rc62.ko I_KNOW=1 bash kmod/go.sh
#   ★这一发含一笔写(4 字节，只改 .cfi_jt 桩里的 B，表项不动)；脚本自己有两道闸：
#     ① 前测没复现 fork EPERM ⇒ 不写；② 设备里的 ko 使用说明里没有 4( ⇒ 不是 rc62 ⇒ 不写。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
SUW=com.suw.manager
TGT=com.termux
RUN=/data/local/tmp/w172_fix3.sh
L=$EV/w172_fix3.txt
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
pk_uid() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }

echo "=== 0) 窗口/uid ==="
echo "  $(A 'echo id=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 先用 rc62 起窗口"; exit 3; }
TGTUID=$(pk_uid "$TGT"); case "$TGTUID" in ''|*[!0-9]*) echo "[x] Termux uid 取不到"; exit 3;; esac
A "echo $TGTUID > /data/local/tmp/w168_u1.uid" >/dev/null
echo "  Termux=$TGTUID"

echo "=== 1) 推三份 + 核 md5(设备侧不许是旧二进制) ==="
adb push kmod/w172_fix3.sh cm57/forkprobe cm57/ksuctl88 /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 $RUN /data/local/tmp/forkprobe /data/local/tmp/ksuctl88; rm -f /data/local/tmp/w172_fix3.out" >/dev/null
for f in kmod/w172_fix3.sh cm57/forkprobe cm57/ksuctl88; do
    LM=$(md5sum "$f" | cut -c1-32); b=$(basename "$f"); RM=$(A "md5sum /data/local/tmp/$b" | cut -c1-32)
    [ "$LM" = "$RM" ] && echo "  ok $b $LM" || { echo "  [x] $b 设备=$RM 本机=$LM ⇒ 停"; exit 3; }
done

echo "=== 2) 跑(前测 → 版本闸 → echo 4 > /proc/ksu_fixcfi → 后测两遍 → id) ==="
fire "@sushd:$RUN" 6
for i in $(seq 1 36); do
    c=$(A "grep -acF '===== DONE' /data/local/tmp/w172_fix3.out 2>/dev/null" | tr -dc '0-9')
    [ "${c:-0}" != "0" ] && { echo "      跑完了($((i*5))s 轮询)"; break; }
    sleep 5
    [ $((i % 6)) = 0 ] && echo "      还在等：up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1) enf=$(A getenforce)"
done
A "cat /data/local/tmp/w172_fix3.out" > "$L" 2>/dev/null
echo "  存证=$L 行数=$(wc -l < "$L")"
grep -aE "^=== F|ko 在册|版本闸|前测|后测|复现标志|LADDER (9|14)|^LC|^KN1|^KN4|^NB (clone_again|setuid|setresuid)|^STAGE|fixcfi|CFIFIX|机器还在|\[x\]|===== DONE" "$L" | cut -c1-170
echo
echo '  ★判据是**同一发里的前后对照**：A1/A2 里 fork=EPERM，B1/B2 里 fork=OK 且 LADDER 9 + id 打出 uid=0 ⇒ #73-B 成立。'
echo "  ★收法：I_KNOW=1 bash kmod/w161_teardown.sh"
