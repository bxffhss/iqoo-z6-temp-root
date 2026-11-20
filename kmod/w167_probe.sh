#!/system/bin/sh
# w167_probe.sh —— 跑 forkprobe 的**两半**：escape 之后 vs 不 escape(正对照)。
#   正对照不可省：如果探针自己跑不起来，"escape 后不能 fork"这条读数就什么都不是(记忆例30/例43 那一族)。
L=/data/local/tmp/w167_probe.out
CTL=/data/local/tmp/ksuctl88
PR=/data/local/tmp/forkprobe
{
    echo "=== PRB up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) ==="
    chmod 755 "$PR" 2>/dev/null
    U=$(cat /data/local/tmp/w167_uid 2>/dev/null | tr -dc '0-9')
    case "$U" in '' | *[!0-9]*) U=10667 ;; esac
    echo "--- 正对照：不 escape，直接跑探针(本进程 uid=$(id -u)) ---"
    "$PR" 2>&1 | grep -aE "PROBE|Seccomp|NoNewPrivs|R[0-9]" | cut -c1-160
    echo "--- 实验：先 escape(降到 $U 再 GRANT_ROOT)，由那个任务 exec 探针 ---"
    "$CTL" grant "$U" "$PR" 2>&1 | grep -aE "GRANT_ROOT|LADDER (9|14)|PROBE|Seccomp|NoNewPrivs|R[0-9]|子进程结束|Killed|Segmentation" | cut -c1-160
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
