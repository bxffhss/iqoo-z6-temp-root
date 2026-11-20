#!/bin/bash
# w170_run.sh —— 一发窗口内的第二次测量：用 tracefs 的 kretprobe 把 clone 的 -1 定位到函数。
#   前提：go.sh 已经起好窗口(模块在、名单里有目标 uid)。用法：bash kmod/w170_run.sh
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
SUW=com.suw.manager
TGT=com.termux
RUN=/data/local/tmp/w170_kpf.sh
L=$EV/w170.txt
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
pk_uid() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }

echo "=== 0) 窗口还在吗 ==="
echo "  $(A 'echo id=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 先跑 go.sh"; exit 3; }
TGTUID=$(pk_uid "$TGT")
case "$TGTUID" in ''|*[!0-9]*) echo "[x] Termux uid 取不到"; exit 3;; esac
A "echo $TGTUID > /data/local/tmp/w168_u1.uid" >/dev/null
echo "  Termux=$TGTUID"

echo "=== 1) 推 + 核 md5 ==="
adb push kmod/w170_kpf.sh /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 $RUN; rm -f /data/local/tmp/w170.out" >/dev/null
LM=$(md5sum kmod/w170_kpf.sh | cut -c1-32); RM=$(A "md5sum $RUN" | cut -c1-32)
[ "$LM" = "$RM" ] && echo "  ok w170_kpf.sh $LM" || { echo "[x] 设备侧不是本机这份(设备=$RM 本机=$LM)"; exit 3; }

echo "=== 2) 跑(装 kretprobe→escape 任务 fork→读返回值→摘探针) ==="
fire "@sushd:$RUN" 6
for i in $(seq 1 24); do
    c=$(A "grep -acF '===== DONE' /data/local/tmp/w170.out 2>/dev/null" | tr -dc '0-9')
    [ "${c:-0}" != "0" ] && { echo "      跑完了($((i*5))s 轮询)"; break; }
    sleep 5
done
A "cat /data/local/tmp/w170.out" > "$L" 2>/dev/null
echo "  存证=$L 行数=$(wc -l < "$L")"
cut -c1-170 "$L" | grep -aE "^=== T|  tracefs|  这些符号|  已登记|GRANT_ROOT|LADDER (0|1|14)|cp_clone|cp_clone3|cp_fork|计数|清完|===== DONE|\[x\]"
echo
echo "  ★读法：有 cp_clone 记录且 ret=-1 ⇒ 进了函数，凶手在 clone 里面；**一条 cp_clone 都没有** ⇒ 拒在入口(表项/入口钩子)。"
echo "  ★收法：I_KNOW=1 bash kmod/w161_teardown.sh"
