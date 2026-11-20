#!/usr/bin/env bash
# w603_home_cell.sh —— 牌子那一格的**读数腿**：重启官方 Manager(可选)→ 无障碍树里取首页状态。
#   ★刻意**不发深链**：#113 那条深链是为了把"四个页签"送进树；这里只问"首页有没有自己回到 工作中/32601-2"，
#     发深链就等于我自己替被测对象补了一步，那一格就不算它自己回来的(例 167 同族：别把仪器动作算成被测件的功劳)。
#   判据形状来自 §6.401/#121：`工作中`＋`版本：32601-2`＝牌子在；`不支持`/`-0`/`uapi 不匹配`＝牌子没了。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
TAG=${1:?用法: bash kmod/w603_home_cell.sh <标签> [restart]}
MODE=${2:-restart}
MGR=me.weishu.kernelsu
EV=kmod/w103_evidence
S() { adb shell "$1" 2>&1 | tr -d '\r'; }
adb shell 'input keyevent KEYCODE_WAKEUP; svc power stayon true' >/dev/null 2>&1
sleep 1
S 'input tap 540 2054' >/dev/null 2>&1; sleep 1     # vivo USB/开发模式弹窗会吃掉焦点(一手:mCurrentFocus=VivoUsbDialog)
[ "$MODE" = restart ] && { S "am force-stop $MGR" >/dev/null; sleep 2; }
# ★read 模式也必须把 Manager 顶回前台：rleg 派单会把 suw 顶起来，不补这一手就拍到 suw 的页面(假读数)。
#   对已经是最前台实例的 Manager 来说这条 am start **不会重启进程**(回执 "intent delivered to currently running top-most instance")
#   ⇒ 仍然是"不重启、看它自己会不会重查"那一格。
S "am start -n $MGR/.ui.MainActivity" >/dev/null; sleep 8
FOC=$(S 'dumpsys window 2>/dev/null | grep -aE "mCurrentFocus|mFocusedApp" | head -4')
echo "  焦点行: $(printf '%s' "$FOC" | tr '\n' '|')"
printf '%s' "$FOC" | grep -qa "$MGR/" || { echo "  [x] 焦点不在 Manager ⇒ 这一格按**没测到**算，不当当负读数"; exit 7; }
S "rm -f /sdcard/w603_$TAG.xml; uiautomator dump /sdcard/w603_$TAG.xml >/dev/null 2>&1; ls -l /sdcard/w603_$TAG.xml" | sed 's/^/  dump: /'
adb pull "/sdcard/w603_$TAG.xml" "$EV/w603_$TAG.xml" >/dev/null 2>&1
if [ ! -s "$EV/w603_$TAG.xml" ]; then
    echo "  [x] 无障碍树没产文件 ⇒ 这一格按**没测到**算(不算通过也不算负)"
    exit 7
fi
S 'screencap -p /sdcard/w603.png' >/dev/null; adb pull /sdcard/w603.png "$EV/w603_$TAG.png" >/dev/null 2>&1
echo "  Manager pid=[$(S "pidof $MGR" | tr '\n' ' ')]  up=$(S 'cut -d" " -f1 /proc/uptime')"
PYTHONUTF8=1 python - "$EV/w603_$TAG.xml" <<'PY'
import re, sys, io
s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
st = '不支持' if '不支持' in s else ('工作中' if '工作中' in s else '未知')
v = re.search(r'版本：(\d+)-(\d+)', s)
yr = '越狱' if '越狱' in s else '-'
um = 'uapi不匹配红字在' if '不匹配' in s else '无红字'
tabs = len([t for t in re.findall(r'text="([^"]*)"', s) if t in ('主页', '超级用户', '模块', '设置')])
print("  读回：状态=%s 版本=%s 越狱串=%s %s 页签=%d" % (
    st, ('%s-%s' % (v.group(1), v.group(2))) if v else '读不到', yr, um, tabs))
print("  判据口径：正=工作中∧32601-2∧(我可以不碰它)；负=不支持/版本尾号 0/带 uapi 不匹配红字")
PY
