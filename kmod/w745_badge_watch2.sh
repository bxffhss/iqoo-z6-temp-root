#!/bin/bash
# w745_badge_watch2.sh —— 第 52 发的**修正版** UI 采样器(同窗、0 额外枪)。
#   为什么要有这一版(一手教训)：上一版 w732 连采 40 格，每格都是 `节点=4~20 包在场=否 首行文本=[USB 已连接]`
#     ⇒ 那不是"牌子灭了"，是 **vivo 的 USB 用途选择对话框(pkg=android，模态)把无障碍树整个抢走了**。
#     焦点断言救下这一格(例 174④ 第三次兑现)，但只"记未测"不够——这发的主判据就是显示层，必须能读才行。
#   ⇒ 这一版每格先做**自救三步**再读：焦点不在 Manager ⇒ ①`input keyevent 4` 关模态框(★绝不点"取消"：那一下可能把 adb 数据通道一起关掉)
#     ②`am start` 把 Manager 顶回前台 ③再断言焦点；两拍还读不到就记 UNTESTED，不记"灭了"。
#   ★BACK 事件格的形状照用户口述：牌子亮着时按一下返回 ⇒ 连读 3 格(看是否当场灭) ⇒ 再 `am start` 重进 ⇒ 连读 3 格(看是不是重进才灭)。
#   用法：bash kmod/w745_badge_watch2.sh [轮数=26] [间隔秒=12] [标签=shot52b]
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
export PYTHONUTF8=1

N=${1:-26}
S=${2:-12}
TAG=${3:-shot52b}
BACK_AT=${W745_BACK_AT:-6}
SU_AT=${W745_SU_AT:-14}
PKG=me.weishu.kernelsu
EV=kmod/w103_evidence
CSV=$EV/w745_${TAG}_badge.csv
XDEV=/data/local/tmp/w745.xml
XLOC=$EV/w745_${TAG}_last.xml

A() { timeout 30 adb shell "$1" 2>&1 | tr -d '\r'; }

focus_pkg() { A "dumpsys window 2>/dev/null | grep -a mCurrentFocus | tail -1" | grep -ao "$PKG" | head -1; }

read_badge() {  # $1=后缀名(避免同名覆盖，例 176④)
    local sfx=$1
    A "rm -f $XDEV; uiautomator dump $XDEV >/dev/null 2>&1" >/dev/null
    local bytes=$(A "ls -l $XDEV 2>/dev/null | cut -d' ' -f5" | tr -dc '0-9')
    if [ "${bytes:-0}" = "0" ]; then echo "UNTESTED dump 没产文件"; return; fi
    adb pull "$XDEV" "${XLOC%.xml}_${sfx}.xml" >/dev/null 2>&1
    python kmod/w733_badgetext.py "${XLOC%.xml}_${sfx}.xml" 2>&1 | head -1
}

ensure_manager() {  # 焦点不在 Manager ⇒ 关模态框 + 顶回前台(最多两拍)
    local k
    for k in 1 2; do
        [ -n "$(focus_pkg)" ] && return 0
        A "input keyevent 4" >/dev/null; sleep 1
        A "am start -n $PKG/.ui.MainActivity" >/dev/null 2>&1; sleep 3
    done
    [ -n "$(focus_pkg)" ]
}

: > "$CSV"
echo "轮,up,pid,焦点自救,牌子读数,备注" >> "$CSV"
echo "=== w745 起 标签=$TAG 轮数=$N 间隔=${S}s BACK_AT=$BACK_AT SU_AT=$SU_AT 产物=$CSV ==="
echo "  起点 up=$(A 'cut -d" " -f1 /proc/uptime') pid=$(A "pidof $PKG") enf=$(A 'cat /sys/fs/selinux/enforce') mod=$(A 'grep -c kernelsu /proc/modules')"

for i in $(seq 1 "$N"); do
    UP=$(A 'cut -d " " -f1 /proc/uptime' | tr -dc '0-9.')
    PID=$(A "pidof $PKG" | tr -dc '0-9')
    if ensure_manager; then FIXED=焦点OK; else FIXED=UNTESTED抢不到焦点; fi
    R=$(read_badge "r$i")
    echo "$i,${UP:-?},${PID:-无},$FIXED,\"$R\"" >> "$CSV"
    echo "  轮$i up=${UP:-?} pid=${PID:-无} $FIXED ⇒ $R"

    if [ "$i" = "$BACK_AT" ]; then
        echo "    >> 事件①第 $i 轮：牌子亮着按一次返回，连读 3 格，再重进连读 3 格"
        A "input keyevent 4" >/dev/null; sleep 2
        for k in 1 2 3; do
            R2=$(read_badge "b$k"); P2=$(A "pidof $PKG" | tr -dc '0-9')
            echo "      BACK后$k pid=${P2:-无} ⇒ $R2"
            echo "    ,BACK后$k,${P2:-无},直接读(不自救),\"$R2\"" >> "$CSV"
            sleep 2
        done
        A "am start -n $PKG/.ui.MainActivity" >/dev/null 2>&1; sleep 4
        for k in 1 2 3; do
            ensure_manager || true
            R3=$(read_badge "e$k")
            echo "      重进后$k ⇒ $R3"
            echo "    ,重进后$k,$(A "pidof $PKG" | tr -dc '0-9'),amstart,\"$R3\"" >> "$CSV"
            sleep 2
        done
        A "logcat -d -b crash -b main -t 400" > "$EV/w745_${TAG}_crash_after_back.txt" 2>&1
        echo "      crash 命中=$(grep -acE 'Fatal signal|SIGSYS|RootServerMain|libsu|ANR in ' "$EV/w745_${TAG}_crash_after_back.txt")"
    fi

    if [ "$i" = "$SU_AT" ]; then
        echo "    >> 事件②第 $i 轮：发超级用户深链(用户报的\"卡一下再闪退\")，连读 4 格"
        A "am start -a android.intent.action.VIEW -d ksu://action/superuser $PKG" >/dev/null 2>&1; sleep 5
        for k in 1 2 3 4; do
            R4=$(read_badge "s$k"); P4=$(A "pidof $PKG" | tr -dc '0-9')
            echo "      深链后$k pid=${P4:-无} ⇒ $R4"
            echo "    ,深链后$k,${P4:-无},直接读,\"$R4\"" >> "$CSV"
            sleep 3
        done
        A "logcat -d -b crash -b main -t 600" > "$EV/w745_${TAG}_crash_after_su.txt" 2>&1
        echo "      crash 命中=$(grep -acE 'Fatal signal|SIGSYS|RootServerMain|libsu|ANR in ' "$EV/w745_${TAG}_crash_after_su.txt")"
        grep -aE 'Fatal signal|SIGSYS|RootServerMain|ANR in ' "$EV/w745_${TAG}_crash_after_su.txt" | head -6 | sed 's/^/        LC /'
        A "am start -n $PKG/.ui.MainActivity" >/dev/null 2>&1; sleep 4
    fi
    sleep "$S"
done
echo "=== w745 完 行数=$(grep -ac . "$CSV") 终点 up=$(A 'cut -d" " -f1 /proc/uptime') pid=$(A "pidof $PKG") ==="
echo "  ★口径：只有 $FIXED=焦点OK 的格子能用来判'灭不灭'；UNTESTED 的格子不算证据也不算否据"
