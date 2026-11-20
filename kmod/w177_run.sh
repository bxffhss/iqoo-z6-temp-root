#!/bin/bash
# w177_run.sh —— #77 A 段的一条命令：在活窗口里把 policeprobe 推到设备上，走 agent(@sushd) 跑一遍并拉回存证。
#   前提：kmod/go.sh 已经把窗口起好(模块在册 + stage 跑完 + bind su 装好)。
#   ★这一发**纯读**(探针喂的参数就算进了本体也不会真挂上/真装模块)，唯一副作用是在 /data/local/tmp 造一个自己的文件再删掉。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
SUW=com.suw.manager
RUN=/data/local/tmp/w177_pp.sh
L=$EV/w177_pp.txt
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }

echo "=== 0) 窗口在不在 ==="
echo "  $(A 'echo id=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 先起窗口"; exit 3; }

echo "=== 1) 推两份 + 核 md5 ==="
adb push kmod/w177_pp.sh cm57/policeprobe /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 $RUN /data/local/tmp/policeprobe; rm -f /data/local/tmp/w177_pp.out" >/dev/null
for f in kmod/w177_pp.sh cm57/policeprobe; do
    LM=$(md5sum "$f" | cut -c1-32); b=$(basename "$f"); RM=$(A "md5sum /data/local/tmp/$b" | cut -c1-32)
    [ "$LM" = "$RM" ] && echo "  ok $b $LM" || { echo "  [x] $b 设备=$RM 本机=$LM ⇒ 停"; exit 3; }
done

echo "=== 2) 跑(@sushd 派 agent 执行) ==="
fire "@sushd:$RUN" 6
for i in $(seq 1 30); do
    c=$(A "grep -acF '===== DONE' /data/local/tmp/w177_pp.out 2>/dev/null" | tr -dc '0-9')
    [ "${c:-0}" != "0" ] && { echo "      跑完了($((i*5))s 轮询)"; break; }
    sleep 5
    [ $((i % 6)) = 0 ] && echo "      还在等：up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1) enf=$(A getenforce)"
done
A "cat /data/local/tmp/w177_pp.out" > "$L" 2>/dev/null
echo "  存证=$L 行数=$(wc -l < "$L") 结尾=$(tail -1 "$L" | cut -c1-60)"
echo "--- 对照组(必须没有 EPERM，否则本发的 EPERM 不能归给 vr) ---"
grep -aE "^CTRL" "$L" | cut -c1-170
echo "--- 被管组 ---"
grep -aE "^POL " "$L" | cut -c1-170
echo "--- 上下文与副作用 ---"
grep -aE "^\[起点\]|^\[终点\]|A 段起点|B0 rc|STAGE|挂载=|===== DONE" "$L" | cut -c1-170
