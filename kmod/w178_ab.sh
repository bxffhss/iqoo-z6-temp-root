#!/bin/bash
# w178_ab.sh —— #78 的单变量前后对照：活窗口里翻 `ksu_capclamp`，各跑一遍 Termux 的 su + policeprobe。
#   前提：窗口用 rc63 起 —— KO=kmod/kernelsu_rc63.ko I_KNOW=1 bash kmod/go.sh
#   ★判据三条(缺一不算成)：
#     ① POL 组随开关翻转：clamp=0 应当还是 11 条 EPERM(=负对照**当场重做**，不是引用历史)；clamp=1 应当一条 EPERM 都没有；
#     ② CTRL 组两遍都全绿(一旦出 EPERM，本发的归因就塌了，见例48)；
#     ③ /proc/ksu_cfiscan 两遍都还是 22 ⇒ 证明"root 能干活"是靠我们自己发的 cred 形状，不是又写回了一条厂商桩。
#   ★跑法：bash kmod/w178_ab.sh        (中途会 force-stop suw，这是唯一 root 通道，不能卸)
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
SUW=com.suw.manager
SET=/data/local/tmp/w178_set.sh
CHMOD=/data/local/tmp/w177_ch.sh

fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
waitdone() {  # waitdone <文件> <标记> <轮数>
    local f=$1 m=$2 n=$3 i=0 c
    while [ "$i" -lt "$n" ]; do
        c=$(A "grep -acF '$m' $f 2>/dev/null" | tr -dc '0-9')
        [ "${c:-0}" != "0" ] && { echo "      ($f 有[$m])"; return 0; }
        sleep 5; i=$((i+1))
    done; echo "      [x] 等满 $((n*5))s 没有[$m]"; return 1; }
setsync() {   # setsync <0|1>：把目标值写进 want.txt(那个动词带不上命令行参数)，再让 agent 执行设置脚本
    A "echo $1 > /data/local/tmp/w178_want.txt; rm -f /data/local/tmp/w178_set.out" >/dev/null
    fire "@sushd:$SET" 6
    waitdone /data/local/tmp/w178_set.out "===== DONE" 12 || return 1
    A "grep -a CAPCLAMP_NOW /data/local/tmp/w178_set.out" | tail -1
}
runleg() {   # runleg <标签>：Termux su 里跑探针并拉回(探针自己会 0600 ⇒ 用 root 补 chmod)
    local tag=$1
    rm -f "$EV/w178_$tag.txt"
    bash kmod/w177_termux.sh > "$EV/w178_$tag.termux.log" 2>&1
    fire "@sushd:$CHMOD" 8
    A "cat /data/local/tmp/pp_su.txt" > "$EV/w178_$tag.txt" 2>/dev/null
    echo "      存证=$EV/w178_$tag.txt 行数=$(wc -l < "$EV/w178_$tag.txt")"
    grep -aE "^\[起点\]" "$EV/w178_$tag.txt" | head -1 | cut -c1-200 | sed 's/^/      /'
    echo "      POL 组 EPERM 条数=$(grep -a '^POL ' "$EV/w178_$tag.txt" | grep -ac 'errno=1 ')"
    echo "      CTRL 组 EPERM 条数=$(grep -a '^CTRL ' "$EV/w178_$tag.txt" | grep -ac 'errno=1 ')"
    echo "      DONE 行=$(tail -1 "$EV/w178_$tag.txt" | cut -c1-40)"
}

echo "=== 0) 前置：这一发的 ko 得是 rc63(带着那个开关) ==="
echo "  $(A 'echo id=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 先起窗口"; exit 3; }
[ -n "$(A 'ls /sys/module/kernelsu/parameters/ksu_capclamp 2>/dev/null')" ] || { echo "[x] 没有 /sys/module/kernelsu/parameters/ksu_capclamp ⇒ ko 不是 rc63，停(什么都不设)"; exit 3; }
adb push kmod/w178_set.sh kmod/w177_ch.sh cm57/policeprobe /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 $SET $CHMOD /data/local/tmp/policeprobe; rm -f /data/local/tmp/pp_su.txt" >/dev/null
for f in kmod/w178_set.sh kmod/w177_ch.sh cm57/policeprobe; do
    LM=$(md5sum "$f" | cut -c1-32); b=$(basename "$f"); RM=$(A "md5sum /data/local/tmp/$b" | cut -c1-32)
    [ "$LM" = "$RM" ] && echo "  ok $b $LM" || { echo "  [x] $b 设备=$RM 本机=$LM ⇒ 停"; exit 3; }
done

echo "=== 1) 负对照：clamp=0(=rc62 行为) 跑一遍 ==="
setsync 0
runleg off

echo "=== 2) 实验：clamp=1 再跑一遍(唯一变的那一格) ==="
setsync 1
runleg on

echo "=== 3) 机制侧复核：桩没被动过(应还是 22 条被管) ==="
bash kmod/w171_run.sh > "$EV/w178_cfiscan.log" 2>&1
grep -aE "VRCFI 结束" "$EV/w178_cfiscan.log" | tail -1 | cut -c1-160 | sed 's/^/      /'

echo "=== 4) 判读(打印出来，别靠我事后猜) ==="
for t in off on; do
    L=$EV/w178_$t.txt
    if [ ! -s "$L" ]; then echo "  [$t] 没有存证 ⇒ 这一腿没跑成"; continue; fi
    grep -aq "policeprobe DONE" "$L" || echo "  [$t] [警告] 存证没有 DONE 行 ⇒ 可能是半截(例39)"
    echo "  [$t] 起点: $(grep -a '^\[起点\]' "$L" | head -1 | cut -c1-190)"
    echo "       POL EPERM=$(grep -a '^POL ' "$L" | grep -ac 'errno=1 ')  CTRL EPERM=$(grep -a '^CTRL ' "$L" | grep -ac 'errno=1 ')  总格=$(grep -acE '^(POL|CTRL) ' "$L")"
done
echo "  ★期望：off=POL EPERM 11 / on=POL EPERM 0；两遍 CTRL EPERM 都 0；cfiscan 两遍都 22"
echo "  ★收法：I_KNOW=1 bash kmod/w161_teardown.sh"
