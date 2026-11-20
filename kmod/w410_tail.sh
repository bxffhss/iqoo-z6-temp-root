#!/system/bin/sh
# w410_tail.sh —— 过线之后(up≥2402)的末端证人：只问内核活表，不读 dmesg(§6.329/190)。
#   ★这一条腿本身就是"行为半格"的证人：它能跑起来 = 装载后 30 分钟 root 通道还在(suw→shd 派单仍可用)。
L=/data/local/tmp/w410_tail.out
{
    echo "=== TAIL up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) ==="
    C=""
    for c in /data/local/tmp/ksuctl87 /data/local/tmp/ksuctl; do
        [ -x "$c" ] && { C="$c"; break; }
    done
    if [ -n "$C" ]; then
        echo "用 $C"
        "$C" list 2>&1 | grep -a NEW_GET_ALLOW_LIST | cut -c1-200 | sed 's/^/  /'
        for T in 10342 10667 10104 2000; do
            echo "  granted[$T]: $(  "$C" granted "$T" 2>&1 | grep -a UID_GRANTED_ROOT | cut -c1-140 )"
        done
        echo "  mgr: $( "$C" mgr 2>&1 | grep -a GET_MANAGER_APPID | cut -c1-140 )"
    else
        echo "(没有可执行的 ksuctl ⇒ 本格按没测到算)"
    fi
    MP=$(pidof me.weishu.kernelsu 2>/dev/null | cut -d' ' -f1)
    echo "官方 Manager pid=[$MP] fd 里带 ksu 的条数=$(ls -l /proc/$MP/fd 2>/dev/null | grep -ac ksu)"
    echo "suw pid=[$(pidof com.suw.manager 2>/dev/null)]"
    echo "/system/bin/su 在否=$(ls -l /product/bin/su 2>&1 | head -1 | cut -c1-70)"
    echo "=== DONE ==="
} > "$L" 2>&1
chmod 666 "$L"
