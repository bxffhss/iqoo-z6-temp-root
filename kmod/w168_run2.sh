#!/bin/bash
# w168_run2.sh —— #72 第二遍：**只换 profile 的域**，再跑一次 escape+探针(kmod/w168_c3.sh)。
#   用法：bash kmod/w168_run2.sh [domain]      默认 u:r:kernel:s0
#   ★为什么要单独一遍：第一遍的 C1(王座/default profile)与 C2(域=shell)如果给出不同读数，
#     差别可能同时来自"域"和"默认 vs 名单里的 profile"两件事。这一遍把 uid 固定住、只动域，
#     才是单变量。域用第一遍 C1 读回来的那个串(所以是参数，不是猜的)。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
DOM=${1:-u:r:kernel:s0}
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
SUW=com.suw.manager
TGT=com.termux
L=$EV/w168_c3.txt
RUN=/data/local/tmp/w168_c3.sh
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
pk_uid() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }

echo "=== 0) 窗口还在吗 ==="
echo "  $(A 'echo id=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 这一发没法跑"; exit 3; }
TGTUID=$(pk_uid "$TGT")
case "$TGTUID" in ''|*[!0-9]*) echo "[x] Termux uid 取不到"; exit 3;; esac
A "echo $TGTUID > /data/local/tmp/w168_u1.uid" >/dev/null
echo "  Termux=$TGTUID 要写的域=$DOM"

echo "=== 1) 改这条 profile 的域(只有王座有权发 SET_APP_PROFILE，所以走 suw 的 @setprof) ==="
A "cat /sdcard/Android/data/$SUW/files/ksu_grant.txt 2>/dev/null | tr -d '\\000' | grep -a SETPROF | tail -1" | cut -c1-165 | sed 's/^/  改之前最后一条回执: /'
fire "@setprof:$TGTUID:1:$TGT:$DOM" 10
A "cat /sdcard/Android/data/$SUW/files/ksu_grant.txt 2>/dev/null | tr -d '\\000' | grep -a SETPROF | tail -2" | cut -c1-165 | sed 's/^/  回执: /'

echo "=== 2) 跑 C3(先读回内核名单，再 escape 同一个 uid 跑探针) ==="
adb push kmod/w168_c3.sh cm57/forkprobe /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 $RUN /data/local/tmp/forkprobe; rm -f /data/local/tmp/w168_c3.out" >/dev/null
LM2=$(md5sum cm57/forkprobe | cut -c1-32); RM2=$(A "md5sum /data/local/tmp/forkprobe" | cut -c1-32)
[ "$LM2" = "$RM2" ] && echo "  ok forkprobe $LM2" || { echo "[x] 设备侧 forkprobe 不是本机这份(设备=$RM2 本机=$LM2)"; exit 3; }
LM=$(md5sum kmod/w168_c3.sh | cut -c1-32); RM=$(A "md5sum $RUN" | cut -c1-32)
[ "$LM" = "$RM" ] && echo "  ok w168_c3.sh $LM" || { echo "[x] 设备侧脚本不是本机这份(设备=$RM 本机=$LM)"; exit 3; }
fire "@sushd:$RUN" 6
for i in $(seq 1 30); do
    c=$(A "grep -acF '===== DONE' /data/local/tmp/w168_c3.out 2>/dev/null" | tr -dc '0-9')
    [ "${c:-0}" != "0" ] && { echo "      跑完了($((i*5))s 轮询)"; break; }
    sleep 5
done
A "cat /data/local/tmp/w168_c3.out" > "$L" 2>/dev/null
echo "  存证=$L 行数=$(wc -l < "$L")"
grep -aE "^=== C3|uid=|domain|granted|^PROBE tag|^STATE (attr|status|NR)|^CL[0-9]|^KN[0-9]|^NB (clone|setuid|getpid|read|lseek|newfstatat|fstat|nr42|execve)|^LC|^STAGE|LADDER (9|14)|GRANT_ROOT|enf=|===== DONE" "$L" | cut -c1-165
echo
echo "  ★对照第一遍：C2(域=shell) 的 LC1/CL*/KN* 读数 vs 这一遍的 —— 同 uid、只动域。"
echo "  ★收法：I_KNOW=1 bash kmod/w161_teardown.sh"
