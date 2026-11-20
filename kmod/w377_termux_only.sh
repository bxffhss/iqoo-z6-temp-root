#!/bin/bash
# w377_termux_only.sh —— 第 134 发(Cell Z)行为半格的**替代走法**：不借 root 信道，直接在 Termux 里手敲 su。
#   为什么换路子：suw→shd 那条通道在窗口十几分钟后不再响应(3 次呼叫无输出文件)，而 w118 的 UI 路子
#     只需要 adb(它一直好)——本发问的是"磁盘那份装载时写进去的第二条记录(uid=10667)能不能真出 root"。
#   ★刻意**不带** w118 的第 1 步(@setprof 运行时授权)：那一枪会把"装载时那条记录"换成"运行时下发的 profile"
#     ⇒ 本格唯一要证的正是前者，所以这里一条授权命令都不发；名单里已有 granted[10667]=1(判据③的一手回执)。
#   抄的是 kmod/w118_termux.sh 里已实测过的行(焦点循环 + type_ 的整体单引号 + 落盘判据不依赖截图)。
set -u
cd "$(dirname "$0")/.." || exit 1
A() { MSYS_NO_PATHCONV=1 adb "$@"; }
S() { A shell "$@" 2>&1; }
PKG=com.termux
ACT=com.termux/.app.TermuxActivity
OUT=/data/local/tmp/w377_uu_root.txt

type_() {   # 空格在 input text 里是 %s(§env 坑)，整体交给远端用单引号包住，否则只敲进第一个词
    A shell "input text '$1'" >/dev/null 2>&1
    sleep 1
    A shell input keyevent 66 >/dev/null 2>&1
    sleep "${2:-4}"
}

echo "=== 0) 起点(活窗口 + 名单里 10667 在不在，现读) ==="
S 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(lsmod|grep -c kernelsu) enf=$(getenforce)' | sed 's/^/  /'
[ "$(S 'lsmod | grep -c kernelsu' | tr -dc 0-9)" = "1" ] || { echo "[x] 模块不在 ⇒ 需要活窗口"; exit 2; }
echo "  Termux 现在的 uid=$(S 'pm list packages -U' | grep -a 'package:com.termux:' | tr -dc '0-9')  (★整词匹配，别拿 com.termux.api)"

echo "=== 1) 起 Termux，等焦点 ==="
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

echo "=== 2) 手敲：su → 在 root shell 里把 id/域写进文件(不依赖截图的判据) ==="
type_ "su" 6
type_ "id" 4
type_ "id > $OUT 2>&1" 4
type_ "cat /proc/self/attr/current >> $OUT 2>&1" 4
type_ "ps -A -o USER,PID,NAME | grep -c termux >> $OUT 2>&1" 4
type_ "chmod 666 $OUT" 3
echo "  --- ★判据：$OUT 的内容 ---"
S "ls -l $OUT; cat $OUT" 2>&1 | sed 's/^/  /'
echo "  --- 旁证：Termux 自己的进程身份(它应当还是 uid=10667，不是 root) ---"
S "ps -A -o USER:12s,PID,NAME | grep -m3 termux" | sed 's/^/  /'
echo "  --- 截图(拿不到不影响判据) ---"
A shell screencap -p /data/local/tmp/w377_termux.png >/dev/null 2>&1
A pull /data/local/tmp/w377_termux.png kmod/w103_evidence/w377_termux.png >/dev/null 2>&1 \
    && echo "  存 kmod/w103_evidence/w377_termux.png" || echo "  截图没拿到(不影响判据)"
