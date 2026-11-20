#!/system/bin/sh
# w615_fdshape.sh —— 我那条"读回 fd 数"为什么报 0：把 Manager 的 fd 表**原样**打出来看形状。
#   (例 161 的规矩：负读数先怀疑我的匹配式，别急着当"没装上"。内核这边已经写了 fd=105。)
L=/data/local/tmp/w615_fdshape.out
P=${1:-$(pidof me.weishu.kernelsu 2>/dev/null | cut -d' ' -f1)}
{
    echo "=== SHAPE up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) pid=[$P] ==="
    echo "  fd 表条数=$(ls -l /proc/$P/fd 2>&1 | grep -ac '^l')"
    echo "  --- 含 anon 的行 ---"
    ls -l /proc/$P/fd 2>&1 | grep -ai anon | sed 's/^/    /'
    echo "  --- grep ksu_driver 命中=$(ls -l /proc/$P/fd 2>&1 | grep -ac ksu_driver) / grep -i ksu 命中=$(ls -l /proc/$P/fd 2>&1 | grep -aci ksu) ---"
    echo "  --- 直接 readlink 那几个内核报的号(105/115/116/117) ---"
    for n in 105 115 116 117; do echo "    fd$n -> $(readlink /proc/$P/fd/$n 2>&1)"; done
    echo "  --- 尾 6 行原样(看编号与目标怎么写) ---"
    ls -l /proc/$P/fd 2>&1 | tail -6 | sed 's/^/    /'
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
