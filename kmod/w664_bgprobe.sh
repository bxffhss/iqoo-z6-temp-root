#!/system/bin/sh
# w664_bgprobe.sh —— 0 枪基线：官方 Manager **退到后台**之后进程能活多久。
#   为什么要测：#176 那批发现在窗里"牌子亮 5.5 分钟"是同一种子进程一直活着；用户报"每次只亮 ≈0.5 分钟"。
#   牌子是**进程启动时一次性查询** ⇒ 如果后台被回收，任何"不重开就自己回亮"的用户态办法都无解(§6.406)。
#   本件只读 + 敲一个 HOME 键，不动开关、不装东西、mod=0 也能跑(所以不烧枪)。
L=/data/local/tmp/w664_bgprobe.out
PKG=me.weishu.kernelsu
{
    echo "=== BG up=$(cut -d' ' -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) ==="
    echo "  屏幕=$(dumpsys power 2>/dev/null | grep -a -m1 'mWakefulness=' | tr -d '\r') 焦点=$(dumpsys window 2>/dev/null | grep -a -m1 'mFocusedApp=' | cut -c1-70)"
    am start -n "$PKG/.ui.MainActivity" >/dev/null 2>&1
    sleep 3
    P0=$(pidof "$PKG" | cut -d' ' -f1)
    echo "  起来后 pid=[$P0] up=$(cut -d' ' -f1 /proc/uptime)"
    [ -n "$P0" ] || { echo "  !! 没起来 ⇒ 这格算没测到"; echo "===== DONE NO-START"; exit 2; }
    input keyevent 3
    sleep 2
    echo "  按 HOME 后焦点=$(dumpsys window 2>/dev/null | grep -a -m1 'mFocusedApp=' | cut -c1-70)"
    i=0
    DEAD=""
    while [ "$i" -lt 40 ]; do
        i=$((i + 1))
        sleep 4
        P=$(pidof "$PKG" | cut -d' ' -f1)
        if [ "$P" = "$P0" ]; then R="同一个 pid"; elif [ -z "$P" ]; then R="**进程没了**"; DEAD="$DEAD $i"; else R="换了新 pid=$P"; DEAD="$DEAD $i"; fi
        echo "  t=$((i * 4))s up=$(cut -d' ' -f1 /proc/uptime) pid=[$P] $R"
    done
    echo "  结论线索：消失/更换发生在哪些拍=[$DEAD]"
    echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime)"
} > "$L" 2>&1
chmod 666 "$L"
