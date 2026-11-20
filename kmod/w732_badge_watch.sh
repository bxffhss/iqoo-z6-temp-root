#!/bin/bash
# w732_badge_watch.sh —— 第 52 发的 PC 侧牌子采样器(判据 4/5)：每格只做四件只读事＋两格写死的导航事件。
#   用法：bash kmod/w732_badge_watch.sh [轮数=40] [间隔秒=12] [标签=shot52]
#   ★形状上的三条讲究(都是踩过的坑)：
#     ①**不经 suw/root**：派 rleg 会把 suw 顶到前台 ⇒ 牌子焦点被仪器自己改掉(记忆那条)；这里全走 shell 侧只读命令。
#     ②**每格都断言焦点**：`uiautomator dump` 与 vivo 弹窗/通知栏会抢焦点 ⇒ 焦点不在 Manager 时那格记 UNTESTED，不当"牌子没了"(例 174④)。
#     ③**事件产物名带轮号**：同一发里两次事件若写同名文件，第二次覆盖第一次(例 176④)。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
export PYTHONUTF8=1

N=${1:-40}
S=${2:-12}
TAG=${3:-shot52}
BACK_AT=${W732_BACK_AT:-10}       # 第几轮点返回键(复现用户那一下)
SU_AT=${W732_SU_AT:-20}           # 第几轮发超级用户深链(复现"卡一下再闪退")
PKG=me.weishu.kernelsu
EV=kmod/w103_evidence
mkdir -p "$EV"
CSV=$EV/w732_${TAG}_badge.csv
XDEV=/data/local/tmp/w732.xml
XLOC=$EV/w732_${TAG}_last.xml

A() { timeout 30 adb shell "$1" 2>&1 | tr -d '\r'; }

: > "$CSV"
echo "轮,up,pid,焦点,牌子读数,SIGSYS或signal6,logcat件" >> "$CSV"
echo "=== w732 起 标签=$TAG 轮数=$N 间隔=${S}s BACK_AT=$BACK_AT SU_AT=$SU_AT 产物=$CSV ==="
echo "  起点 up=$(A 'cut -d" " -f1 /proc/uptime') pid=$(A "pidof $PKG") enf=$(A 'cat /sys/fs/selinux/enforce') mod=$(A 'grep -c kernelsu /proc/modules')"

grab_crash() {  # $1=轮号标签
    local f=$EV/w732_${TAG}_crash_r$1.txt
    A "logcat -d -b crash -b main -t 400" > "$f" 2>&1
    grep -acE "Fatal signal|SIGSYS|RootServerMain|libsu|ANR in $PKG" "$f" 2>/dev/null | tr -dc '0-9'
}

for i in $(seq 1 "$N"); do
    UP=$(A 'cut -d " " -f1 /proc/uptime' | tr -dc '0-9.')
    PID=$(A "pidof $PKG" | tr -dc '0-9')
    FOCUS=$(A "dumpsys window 2>/dev/null | grep -a mCurrentFocus | head -1" | grep -ao "[a-z.]*$PKG/[a-zA-Z.]*" | head -1)
    [ -n "$FOCUS" ] || FOCUS=非Manager
    A "rm -f $XDEV; uiautomator dump $XDEV >/dev/null 2>&1" >/dev/null
    B=$(A "ls -l $XDEV 2>/dev/null | cut -d' ' -f5" | tr -dc '0-9')
    if [ "${B:-0}" = "0" ]; then
        READ="UNREADABLE dump 没产文件(首跑会静默，这条必须显式记)"
    else
        adb pull "$XDEV" "$XLOC" >/dev/null 2>&1
        READ=$(python kmod/w733_badgetext.py "$XLOC" 2>&1 | head -1)
    fi
    echo "$i,${UP:-?},${PID:-无},$FOCUS,\"$READ\",,\"\"" >> "$CSV"
    echo "  轮$i up=${UP:-?} pid=${PID:-无} 焦点=$FOCUS ⇒ $READ"

    if [ "$i" = "$BACK_AT" ]; then
        echo "    >> 事件①：第 $i 轮按返回键(复现用户那一下)，之后连读 3 格"
        A "input keyevent 4" >/dev/null; sleep 2
        A "am start -n $PKG/.ui.MainActivity" >/dev/null 2>&1; sleep 3
        for k in 1 2 3; do
            A "rm -f $XDEV; uiautomator dump $XDEV >/dev/null 2>&1" >/dev/null
            adb pull "$XDEV" "${XLOC%.xml}_b$k.xml" >/dev/null 2>&1
            R=$(python kmod/w733_badgetext.py "${XLOC%.xml}_b$k.xml" 2>&1 | head -1)
            F2=$(A "dumpsys window 2>/dev/null | grep -a mCurrentFocus | head -1" | grep -ao "[a-z.]*$PKG/[a-zA-Z.]*" | head -1)
            echo "    >>   重读$k 焦点=${F2:-非Manager} ⇒ $R"
            echo "    ${UP:-?},BACK重读$k,${F2:-非Manager},\"$R\"" >> "$CSV"
        done
        C=$(grab_crash "back$i"); echo "    >> crash 命中行=$C(件 w732_${TAG}_crash_rback$i.txt)"
        echo "$i,${UP:-?},${PID:-无},事件BACK后,,crash命中=$C,w732_${TAG}_crash_rback$i.txt" >> "$CSV"
    fi

    if [ "$i" = "$SU_AT" ]; then
        echo "    >> 事件②：第 $i 轮发超级用户深链(用户报的\"卡一下再闪退\")，之后连读 4 格"
        A "am start -a android.intent.action.VIEW -d ksu://action/superuser $PKG" >/dev/null 2>&1; sleep 4
        for k in 1 2 3 4; do
            A "rm -f $XDEV; uiautomator dump $XDEV >/dev/null 2>&1" >/dev/null
            adb pull "$XDEV" "${XLOC%.xml}_s$k.xml" >/dev/null 2>&1
            R=$(python kmod/w733_badgetext.py "${XLOC%.xml}_s$k.xml" 2>&1 | head -1)
            P2=$(A "pidof $PKG" | tr -dc '0-9')
            echo "    >>   重读$k pid=${P2:-无} ⇒ $R"
            echo "    ${UP:-?},SU重读$k,pid=${P2:-无},\"$R\"" >> "$CSV"
            sleep 3
        done
        C=$(grab_crash "su$i"); echo "    >> crash 命中行=$C(件 w732_${TAG}_crash_rsu$i.txt)"
        echo "$i,${UP:-?},${PID:-无},事件SU深链后,,crash命中=$C,w732_${TAG}_crash_rsu$i.txt" >> "$CSV"
        A "am start -n $PKG/.ui.MainActivity" >/dev/null 2>&1; sleep 3
    fi
    sleep "$S"
done
echo "=== w732 完 行数=$(grep -ac . "$CSV") 终点 up=$(A 'cut -d" " -f1 /proc/uptime') ==="
echo "  判据口径：全程不许出现『牌子=不支持』；出现的那一行必须同格写清 pid 变没变＋root 侧 w731 同 up 的 fd_ksu"
echo "  ★这份 CSV 只是显示层读数，**分家要靠 w731_root.txt 同 up 对齐**，别看单边下结论"
