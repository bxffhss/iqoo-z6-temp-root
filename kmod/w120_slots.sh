#!/system/bin/sh
# w120：把内核 `/proc/ksu_slots` 里那份 CFIFIX/SLOTTBL 报告**整份**抄出来(不 grep)。
#   第一百一十八发教训：stage 里是 grep 过滤后的片段 ⇒ "只看到 3 条 CFIFIX"可能只是被截/被筛，
#   不能当"另外两条没处理"的证据。判据要拿原始量。
L=/data/local/tmp/w120_slots.txt
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    echo "--- /proc/ksu_slots ---"
    cat /proc/ksu_slots 2>&1
    echo "--- 再触发一次只读报告(echo 0 > /proc/ksu_fixcfi 不写任何东西) ---"
    echo 0 > /proc/ksu_fixcfi 2>&1
    cat /proc/ksu_slots 2>&1 | grep -a CFIFIX
    echo "--- 挂载与 su 可见性现状 ---"
    grep -a ' /system/bin ' /proc/mounts 2>&1
    ls -l /system/bin/su 2>&1
} >"$L" 2>&1
chmod 666 "$L"
