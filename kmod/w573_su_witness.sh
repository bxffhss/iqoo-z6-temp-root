#!/system/bin/sh
# w573_su_witness.sh —— 第 45 发的**内核侧证人腿**(root 跑，必须排在 w426 恢复执法之前)：
#   回答"app 敲 /system/bin/su 那一下，改道到底 fire 没 fire"——`sucompat.c` 自己打 `KSUBEAT SU1*/SU1a/SU1d`，
#   这是分辨"没成功／成功了但屏幕看不见／根本没进改道"三条候选的唯一一手证人(#209 之后补的前置读数)。
OUT=/data/local/tmp/w573_su_witness.out
: > "$OUT"
{
    echo "=== W573 起点 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) ==="
    echo "--- 1) dmesg 里 sucompat 那段(最后 14 行 SU 相关) ---"
    /system/bin/dmesg 2>/dev/null | grep -a 'KSUBEAT SU' | tail -14
    echo "--- 2) dmesg 里 decline/名单相关(最后 8 行) ---"
    /system/bin/dmesg 2>/dev/null | grep -a 'KSUBEAT SD1 decline' | tail -4
    echo "--- 3) Termux 各进程的 fd 表里有没有 ksu_driver(独立第二来源) ---"
    for P in $(pidof com.termux); do
        echo "pid=$P ppid=$(cut -d' ' -f4 /proc/$P/stat 2>/dev/null) ksu_driver个数=$(ls -l /proc/$P/fd 2>&1 | grep -c ksu_driver) 明细=$(ls -l /proc/$P/fd 2>&1 | grep -a ksu_driver | head -2 | tr '\n' '|')"
    done
    echo "--- 4) 载荷件的现状(屏幕之外的那一半证人) ---"
    echo "w572_root.out: $(ls -l /data/local/tmp/w572_root.out 2>&1)"
    echo "内容=$(cat /data/local/tmp/w572_root.out 2>&1 | tr '\n' '|' | cut -c1-420)"
    echo "靶子 w572_probe: $(ls -l /data/local/tmp/w572_probe 2>&1)"
    echo "===== DONE"
} > "$OUT" 2>&1
chmod 666 "$OUT" 2>/dev/null
