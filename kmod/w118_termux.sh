#!/bin/bash
# w118_termux.sh —— **用户症状的原样复现与验收**：在真实第三方 app(Termux) 自己的终端里手敲 `su`。
# 前置：活窗口(模块在、stage 已跑)，且 §6.116 那两格已修：
#   ① `ksu_hook_mask` 开了位 3/4(newfstatat/faccessat) ⇒ app 的 `access("/system/bin/su")` 探测会成功；
#   ② rc57 的 CFIFIX 把这两条桩也写回本体 ⇒ 从钩子里调原实现不会打死机器。
# 用法：bash kmod/w118_termux.sh            # 授权 Termux + 敲 su + 截图
#       UID=10667 PKG=com.termux bash kmod/w118_termux.sh
# ★判据只看两张图/一段文字里有没有 `uid=0(root)`；截图拿不到时(息屏/安全窗)退回 `dumpsys window` 的焦点
#   + Termux 自己写出的文件(见下：把 `id` 重定向到 /sdcard 里再读，不依赖截图)。
set -u
cd "$(dirname "$0")/.." || exit 1
A() { MSYS_NO_PATHCONV=1 adb "$@"; }
S() { A shell "$@" 2>&1; }
# ★不能叫 UID：Git Bash 自己导出 UID(本机是 197108 这种 Windows 侧 id)，会把默认值悄悄顶掉，
#   于是 @setprof 授权到一个不存在的 uid、判据全打空(§6.171 一手)。要覆盖只认 TERMUX_UID。
UID_=${TERMUX_UID:-10667}
PKG=${PKG:-com.termux}
ACT=${ACT:-com.termux/.app.TermuxActivity}
OUT=/data/local/tmp/uu_root.txt   # §6.170 一手：原来写 /sdcard/Android/data/com.termux/files/uu.txt，root 那个 mount ns 里根本没这个目录
                              #   ⇒ "不依赖截图的判据"当场失效(can't create … No such file or directory)。/data/local/tmp 两边都在。

fire() {
    A shell am force-stop com.suw.manager >/dev/null 2>&1
    sleep 1
    A shell "am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1
    sleep "${2:-8}"
}
type_() {   # type_ <文本> [<等待秒>]：往当前焦点窗口敲一串 + 回车
    # ★必须整体用单引号交给远端：`input text a b c` 会被远端 shell 按空格拆开，只敲进 "a"
    #   (Git Bash 这边再套一层，所以远端命令整体是双引号)。
    A shell "input text '$1'" >/dev/null 2>&1
    sleep 1
    A shell input keyevent 66 >/dev/null 2>&1
    sleep "${2:-4}"
}

echo "=== 0) 起点 ==="
S 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(lsmod|grep -c kernelsu) enf=$(getenforce)' | sed 's/^/  /'
[ "$(S 'lsmod | grep -c kernelsu' | tr -dc 0-9)" = "1" ] || { echo "[x] 模块不在 ⇒ 这一发要活窗口跑"; exit 2; }

echo "=== 1) 授权 $PKG(uid=$UID_) —— 走我们自己的 Manager(only_manager) ==="
fire "@setprof:$UID_:1:$PKG" 10
S 'grep -a SETPROF /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -2' | sed 's/^/  /'

echo "=== 2) 起 Termux，等它拿到焦点 ==="
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

echo "=== 3) 手敲：先 su，再在 root shell 里把 id 写到文件(不依赖截图的判据) ==="
type_ "su" 6
type_ "id" 4
type_ "id > $OUT 2>&1" 4
type_ "cat /proc/self/attr/current >> $OUT 2>&1" 4
type_ "chmod 666 $OUT" 3   # root 的 umask 会留 0600 ⇒ PC 侧 cat 只拿到 Permission denied
echo "  --- Termux 里那条命令写出来的文件(★判据) ---"
S "cat $OUT 2>&1" | sed 's/^/  /'
echo "  --- 截图(可能因安全窗/息屏拿不到，拿不到不影响判据) ---"
A shell screencap -p /data/local/tmp/w118_termux.png >/dev/null 2>&1
MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w118_termux.png kmod/w103_evidence/w118_termux.png >/dev/null 2>&1 \
    && echo "  存 kmod/w103_evidence/w118_termux.png" || echo "  截图没拿到(不影响判据)"
echo "  --- Termux 自己的 uid/域(旁证：它确实是 $UID_ 而不是 root 的守护) ---"
S "ps -A -o USER,PID,NAME | grep -m2 ${PKG##*.}" | sed 's/^/  /'
echo "=== 完(★收尾记得 adb reboot：临时 root 不持久化) ==="
