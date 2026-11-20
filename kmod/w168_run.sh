#!/bin/bash
# w168_run.sh —— 窗口已经起来了(go.sh 跑通)之后，一发把 #72 的三个上下文读完。
#   只读测量：不改 ko、不改名单以外的东西(除了把目标 uid 的 profile 补上，那是交付本来就要的一步)、不装机。
#   ★规矩：跑之前先核 md5(设备上不能是旧二进制，§6.155 那发就是旧 ksuctl 静默丢参数)；
#     跑的时候不要改脚本(§记忆"跑着的时候改脚本⇒解析错位")。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
SUW=com.suw.manager
TGT=com.termux
PR=/data/local/tmp/forkprobe
CTL=/data/local/tmp/ksuctl88
RUN=/data/local/tmp/w168_probe.sh
L=$EV/w168_probe.txt
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
pk_uid() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }

echo "=== 0) 起点：模块在不在、通道接不接活 ==="
echo "  $(A 'echo id=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 窗口没起(先 I_KNOW=1 bash kmod/go.sh)"; exit 3; }

echo "=== 1) 取两个 uid(目标 / 王座)并写进设备侧文件 ==="
TGTUID=$(pk_uid "$TGT"); SUWUID=$(pk_uid "$SUW")
for v in TGTUID SUWUID; do eval "X=\$$v"
    case "$X" in ''|*[!0-9]*) echo "[x] $v 取不到($X) ⇒ 停"; exit 3;; esac; done
echo "  Termux=$TGTUID suw(王座)=$SUWUID"
A "echo $TGTUID > /data/local/tmp/w168_u1.uid; echo $SUWUID > /data/local/tmp/w168_u2.uid" >/dev/null

echo "=== 2) 推三份(+重推，stage 收尾会删我们推的东西)并核 md5 ==="
adb push cm57/forkprobe kmod/w168_probe.sh cm57/ksuctl88 /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 $PR $CTL $RUN; rm -f /data/local/tmp/w168_probe.out" >/dev/null
for f in cm57/forkprobe cm57/ksuctl88 kmod/w168_probe.sh; do
    LM=$(md5sum "$f" | cut -c1-32)
    b=$(basename "$f"); RM=$(A "md5sum /data/local/tmp/$b" | cut -c1-32)
    [ "$LM" = "$RM" ] && echo "  ok $b $LM" || echo "  [x] $b 设备=$RM 本机=$LM ⇒ 停(旧二进制会静默改变判据)"
done
for pair in "$PR forkprobe" "$CTL ksuctl88" "$RUN w168_probe.sh"; do
    set -- $pair; A "ls -l $1" >/dev/null 2>&1
    [ -n "$(A "ls $1 2>/dev/null")" ] || { echo "[x] 设备侧没有 $1"; exit 3; }
done

echo "=== 3) 跑(走 @sushd: 那条 root 通道；一次跑完 C0/C2/C1) ==="
fire "@sushd:$RUN" 6
GOT=0
for i in $(seq 1 40); do
    c=$(A "grep -acF '===== DONE' /data/local/tmp/w168_probe.out 2>/dev/null" | tr -dc '0-9')
    [ "${c:-0}" != "0" ] && { echo "      跑完了(第 $((i*5)) 个 5s 轮询)"; GOT=1; break; }
    sleep 5
    [ $((i % 6)) = 0 ] && echo "      还在等：up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1) enf=$(A getenforce)"
done
A "cat /data/local/tmp/w168_probe.out" > "$L" 2>/dev/null
echo "  存证=$L 行数=$(wc -l < "$L")"
[ "$GOT" = 1 ] || echo "  [!] 没等到 DONE ⇒ 看 $L 里跑到哪一格(STAGE 标号就是干这个的)，别把'没读到'当成'没发生'"

echo "=== 4) 读数(全量在这份文件里；下面只挑分岔口) ==="
grep -aE "^=== P8|^  md5|--- C[012]|^PROBE tag|^STATE (status|attr|NR)|^CL[0-9]|^KN[0-9]|^NB |^LC|^STAGE|LADDER (9|14)|GRANT_ROOT|denied|unrecognized|installed at slot|KSUBEAT|dmesg|===== DONE" "$L" | cut -c1-170
echo
echo "  ★判据读法：C2 与 C1 的差别才是这一发的结论；C0 只是探针自己没问题。"
echo "  ★收法：I_KNOW=1 bash kmod/w161_teardown.sh   (卸载→清→reboot→复核)"
