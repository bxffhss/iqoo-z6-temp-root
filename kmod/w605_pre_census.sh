#!/system/bin/sh
# w605_pre_census.sh —— C1 那一格的**前置读数**：到我起常驻看门狗之前，内核里到底有没有发生过"给别人装 fd"。
#   为什么单独一条：例 167 的教训是"排好了动作顺序≠被测对象此刻没有别的生产者"。
#   stage 的抢装窗口(w161_fdwatch)这发**没起**(它的 log/pid 文件都不在)，但那只是间接证据，
#   甲级证据是内核自己记的：`KSUFDINST 已排队给 pid=` / `KSUFDINST 回调跑在 …` / `NULLFILES skip` 的条数。
#   ★读的是 `dmesg`(活环)，不是 dmesg2.log(那是 2 MB 定长轮转，数到 0 不是否据)——两样都打，并写明各自覆盖区间。
L=/data/local/tmp/w605_pre_census.out
{
    echo "=== PRE up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) ==="
    R=/data/local/tmp/w605_ring.txt
    dmesg > "$R" 2>&1
    echo "  环快照: 行数=$(wc -l < "$R") 字节=$(wc -c < "$R") 覆盖=[$(head -1 "$R" | cut -c1-40)] → [$(tail -1 "$R" | cut -c1-40)]"
    chmod 666 "$R"
    echo "  KSUFDINST 已排队=$(grep -ac 'KSUFDINST 已排队' "$R")"
    echo "  KSUFDINST 回调跑在=$(grep -ac 'KSUFDINST 回调跑在' "$R")"
    echo "  NULLFILES skip=$(grep -ac 'NULLFILES skip' "$R")"
    echo "  Crowning=$(grep -ac 'Crowning manager' "$R")"
    echo "  --- 逐条抄回(最多 10 条) ---"
    grep -aE 'KSUFDINST|Crowning manager|NULLFILES' "$R" | tail -10 | sed 's/^/    /'
    echo "  触发口: $(ls -l /proc/ksu_install_fd 2>&1 | tail -1)"
    echo "  stage 看门狗痕迹: log=$(ls /data/local/tmp/w161_fdwatch.log 2>&1|tail -1) pid=$(cat /data/local/tmp/w161_fdwatch.pid 2>/dev/null)"
    echo "  Manager pid=[$(pidof me.weishu.kernelsu 2>/dev/null | tr '\n' ' ')]"
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
