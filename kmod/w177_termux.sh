#!/bin/bash
# w177_termux.sh —— #77 的 B 段：**交付态**那条路上跑 policeprobe(Termux 里手敲 su ⇒ root shell 里执行探针)。
#   与 A 段(w177_run.sh，走 agent)的区别：这一段的任务是**从第三方 app 经 su 换过来的**，
#   所以它测的才是"用户拿到授权之后到底能不能干活"。
# 前置：活窗口 + bind su 已装 + Termux 在名单里(go.sh 第 5.5 步已经加过)。
set -u
cd "$(dirname "$0")/.." || exit 1
A() { MSYS_NO_PATHCONV=1 adb "$@"; }
S() { A shell "$@" 2>&1; }
UID_=${TERMUX_UID:-10667}
PKG=${PKG:-com.termux}
ACT=${ACT:-com.termux/.app.TermuxActivity}
OUT=/data/local/tmp/pp_su.txt
EV=kmod/w103_evidence; mkdir -p "$EV"

fire() {
    A shell am force-stop com.suw.manager >/dev/null 2>&1
    sleep 1
    A shell "am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1
    sleep "${2:-8}"
}
type_() {
    A shell "input text '$1'" >/dev/null 2>&1
    sleep 1
    A shell input keyevent 66 >/dev/null 2>&1
    sleep "${2:-4}"
}

echo "=== 0) 起点 ==="
S 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(lsmod|grep -c kernelsu) enf=$(getenforce)' | sed 's/^/  /'
[ "$(S 'lsmod | grep -c kernelsu' | tr -dc 0-9)" = "1" ] || { echo "[x] 模块不在 ⇒ 这一发要活窗口跑"; exit 2; }
S "md5sum /data/local/tmp/policeprobe 2>&1" | sed 's/^/  探针: /'

echo "=== 1) 确认名单里有 $PKG(uid=$UID_) ==="
fire "@setprof:$UID_:1:$PKG" 10
S 'grep -a SETPROF /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -2' | sed 's/^/  /'

echo "=== 2) 起 Termux，等焦点 ==="
A shell input keyevent 224 >/dev/null 2>&1
A shell 'svc power stayon true; wm dismiss-keyguard' >/dev/null 2>&1
A shell am force-stop "$PKG" >/dev/null 2>&1
sleep 2
A shell am start -n "$ACT" >/dev/null 2>&1
for i in $(seq 1 12); do
    sleep 3
    F=$(A shell dumpsys window 2>/dev/null | grep -aE "mFocusedApp=|mCurrentFocus=" | tail -2 | tr "\n" " ")
    case "$F" in *VivoUsbDialog*) echo "    USB 弹窗挡着 ⇒ 点取消"; A shell "input tap 540 2059" >/dev/null 2>&1; sleep 2;; esac
    case "$F" in *"$PKG"*) echo "  焦点 ok: $F"; break;; *) echo "  焦点=$F";; esac
done
S "rm -f $OUT" >/dev/null

echo "=== 3) 手敲 su，然后在 root shell 里跑探针(输出落文件，不依赖截图) ==="
type_ "su" 6
type_ "id" 3
type_ "/data/local/tmp/policeprobe su > $OUT 2>&1" 8
type_ "echo rc=\$? >> $OUT" 3
type_ "chmod 666 $OUT" 3
echo "  --- 探针在 su 里的输出(★判据) ---"
S "cat $OUT 2>&1" | sed 's/^/  /'
S "cat $OUT 2>&1" > "$EV/w177_pp_su.txt"
A shell screencap -p /data/local/tmp/w177_termux.png >/dev/null 2>&1
MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w177_termux.png "$EV/w177_termux.png" >/dev/null 2>&1 \
    && echo "  存 $EV/w177_termux.png" || echo "  截图没拿到(不影响判据)"
