#!/system/bin/sh
# 一次性基准：量化老/新心跳循环的每秒 execve 次数(上界，dd 源换成不阻塞的 /dev/null)。
L=/data/local/tmp/w200_hb_bench.txt
rm -f "$L"
cd /data/local/tmp || exit 1

# 老形态：每条日志 3 次 fork(子 shell+cut 各算 1、dd、sync)，无 sleep
old_body() {
    echo "--- HB up=$(cut -d' ' -f1 /proc/uptime) ---" >> hb.txt
    dd if=/dev/null bs=512 count=1 2>/dev/null >> hb.txt
    sync
}
# 新形态：read 不 fork、sync 每 8 条一次、每轮 sleep 0.05
new_body() {
    read U rest < /proc/uptime
    echo "--- HB up=$U ---" >> hb.txt
    dd if=/dev/null bs=512 count=1 2>/dev/null >> hb.txt
    N=$((N + 1))
    [ $((N % 8)) -eq 0 ] && sync
    sleep 0.05
}

for mode in old new; do
    case "$mode" in
        old) W=3; T=200 ;;   # 老的上限太高，定次数
        new) W=0; T=60 ;;    # 新的被 sleep 钉住，定次数会太久 ⇒ 下面按秒测
    esac
    N=0
    if [ "$mode" = new ]; then
        S0=$(cut -d' ' -f1 /proc/uptime)
        i=0
        while [ $((i * 100)) -lt 300 ]; do i=$((i + 1)); new_body; done
        S1=$(cut -d' ' -f1 /proc/uptime)
    else
        S0=$(cut -d' ' -f1 /proc/uptime)
        i=0
        while [ "$i" -lt "$T" ]; do i=$((i + 1)); old_body; done
        S1=$(cut -d' ' -f1 /proc/uptime)
    fi
    d=$(awk "BEGIN{printf \"%.3f\", $S1 - $S0}")
    rps=$(awk "BEGIN{printf \"%.1f\", $i / ($S1 - $S0)}")
    echo "$mode: iters=$i 用时=${d}s ⇒ ${rps} 轮/秒" >> "$L"
done
rm -f /data/local/tmp/hb.txt
echo "BENCH-DONE" >> "$L"
