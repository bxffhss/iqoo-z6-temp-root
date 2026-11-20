#!/system/bin/sh
# w155_mwloop.sh —— 挂载存活取样循环(被 w155_mountwatch.sh 用 setsid 甩出去跑，别直接派发它)。
# 每 20 秒一行，最多 60 行(=20 分钟)：覆盖"挂载建立 → 一路用 su → 收尾卸载"整个窗口。
# ★每行都带 `up=`，所以事后能把它和 w135_off 那份回读的 up **对齐**(不靠时间戳猜)。
# ★**正对照**(记忆里的老规矩：只有阴性结果没有"我看得见阴性"的阳性对照 = 这一格等于没测)：
#   计划内的卸载**必须**被记到 —— 连续两行 `mount=0` 就写一行 `MW-END` 收工。
#   于是收尾判据能问三件事：卸载前有没有掉过(结论)、卸载后看见没看见没了(正对照)、
#   两样都对，那句"这一窗扛住了"才带信息量。
L=/data/local/tmp/w155_mw.out
i=0
gone=0
while [ $i -lt 60 ]; do
    U=$(cut -d' ' -f1 /proc/uptime)
    M=$(grep -ac pbin /proc/self/mountinfo 2>/dev/null)
    if ls -l /product/bin/su >/dev/null 2>&1; then S=OK; else S=MISS; fi
    N=$(ls -A /product/bin 2>/dev/null | wc -l)
    echo "MW up=$U uid=$(id -u) mount=$M su=$S tgt_n=$N" >>"$L" 2>&1
    chmod 666 "$L" 2>/dev/null
    i=$((i + 1))
    if [ "${M:-1}" = 0 ]; then
        gone=$((gone + 1))
        if [ $gone -ge 2 ]; then
            echo "MW-END up=$U reason=mount-gone samples=$i" >>"$L" 2>&1
            break
        fi
    else
        gone=0
    fi
    sleep 20
done
