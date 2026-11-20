#!/bin/bash
# w230_run.sh —— 在 Termux 里跑 app 侧探针 w230.sh 并把屏幕存证拉回来(第 100 发/#109)。
#   为什么要有它：执法下 app 写的文件 root 腿读不到(app_data_file)、而 root 腿自己的域读不了 Termux 目录
#     ⇒ **屏幕是唯一通道**(§6.221③)，所以每跑一次必须留一张图，不能只看 adb 返回。
#   用法: bash kmod/w230_run.sh <标签，如 perf / enf>
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
L=${1:?用法: w230_run.sh <标签>}
PROBE=${PROBE:-/data/data/com.termux/files/usr/bin/w230.sh}   # ★第 101 发(#112)换 w240.sh
PREF=${PREF:-w230}                                            # 存证文件名前缀
EV=kmod/w103_evidence
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
A "input keyevent KEYCODE_WAKEUP; svc power stayon true" >/dev/null 2>&1
A "am start -n com.termux/.app.TermuxActivity" >/dev/null 2>&1
sleep 4
# 先在空提示符上敲一次回车，保证这次看到的都是这次的输出(别把上一轮的旧屏当实时读数)
A "input keyevent 66" >/dev/null 2>&1
sleep 1
A "input text sh%s$PROBE" >/dev/null 2>&1
A "input keyevent 66" >/dev/null 2>&1
sleep 6
adb exec-out screencap -p > "$EV/${PREF}_$L.png" 2>/dev/null
echo "  存证 $EV/${PREF}_$L.png  尺寸=$(wc -c < "$EV/${PREF}_$L.png" | tr -dc '0-9') 字节"
# ★两个口径都要打，且"取不到值"要长得跟"值"不一样(例59)
RAW=$(A 'cat /sys/fs/selinux/enforce 2>&1')
GE=$(A 'getenforce')
UP=$(A 'cut -d " " -f1 /proc/uptime' | cut -d. -f1)
echo "  enf 权威读数: raw=[$RAW] getenforce=[$GE] up=$UP"
