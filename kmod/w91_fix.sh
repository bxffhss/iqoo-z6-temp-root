#!/system/bin/sh
# 窗口 91 的主实验：先测基线(应当全 EPERM)，再 `echo 1 > /proc/ksu_fixcfi` 只下一笔
#   **sys_call_table[nr] = 本体地址** 的 8 字节数据写(这台机有先例：KSU 每发都这么写 slot 42)，
#   然后立刻复跑同一份阶梯。判据只看两行：LADDER 1..4 与 LADDER 9。
# ★为什么不一次把"改桩"也做掉：第九十发两笔一起下，机器当场重启，连"是哪笔炸的"都分不开。
L=/data/local/tmp/w91_fix.out
K=/data/local/tmp/ksuctl86
{
    echo "起点 up=$(cut -d' ' -f1 /proc/uptime)"
    echo "===== A) 基线：还没动任何东西 ====="
    "$K" grant 10315 >/data/local/tmp/w91_a.out 2>&1
    grep -aE 'LADDER [0-9]' /data/local/tmp/w91_a.out
    echo "===== B) 下那一笔表项写(echo 1 > /proc/ksu_fixcfi) ====="
    ls -l /proc/ksu_fixcfi 2>&1
    echo 1 > /proc/ksu_fixcfi 2>&1; echo "写入口 rc=$?"
    sleep 1
    echo "--- CFIFIX 那几行(写之前/之后的表项与复读)："
    cat /proc/ksu_slots 2>&1 | tr '|' '\n' | grep -a -A2 "ksu_fixcfi 触发" | head -20
    cat /proc/ksu_slots 2>&1 | tr '|' '\n' | grep -aE "CFIFIX slot=|桩已写回|跳过写" | head -12
    echo "===== C) 复跑同一份阶梯(判据在这) ====="
    "$K" grant 10315 >/data/local/tmp/w91_c.out 2>&1
    grep -aE 'LADDER [0-9]|子进程结束' /data/local/tmp/w91_c.out
    echo "===== D) 带命令的那一格：escape 之后能不能真的 exec 出去 ====="
    "$K" grant 10315 /system/bin/toybox id >/data/local/tmp/w91_d.out 2>&1
    grep -aE 'LADDER [0-9]|uid=0|uid=' /data/local/tmp/w91_d.out | tail -8
    echo "===== E) 正对照：born-root 自己跑同一条 ====="
    /system/bin/toybox id
    echo "收工 up=$(cut -d' ' -f1 /proc/uptime)"
} >"$L" 2>&1
chmod 666 "$L" /data/local/tmp/w91_a.out /data/local/tmp/w91_c.out /data/local/tmp/w91_d.out 2>/dev/null
