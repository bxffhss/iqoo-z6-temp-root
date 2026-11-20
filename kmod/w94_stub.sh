#!/system/bin/sh
# 窗口 94 的主实验：`echo 3 > /proc/ksu_fixcfi` = **只改桩的 B 目标**(表项一个字都不动)。
# 推理(第九十三发一手)：改道者是模块 vr 写进内核 .cfi_jt 表里的三条 B；出厂状态就是 `B 本体`；
#   把"裸本体地址"塞进 sys_call_table 会撞 KCFI 的 cfi_fail(第九十/九十一发两次 PS_HOLD 就是这个)。
#   ⇒ 只改桩 = 与出厂语义等价的那一笔，是唯一还没单独试过、且推理上不该触发 cfi_fail 的写法。
# ★顺序规矩(第九十/九十一发的教训)：先把**所有安全读数落盘**，再按一次触发，触发后第一件事还是落盘。
L=/data/local/tmp/w94_stub.out
K=/data/local/tmp/ksuctl86
{
    echo "起点 up=$(cut -d' ' -f1 /proc/uptime)"
    echo "===== A) 基线阶梯(应当还是 4 格 EPERM) ====="
    "$K" grant 10315 >/data/local/tmp/w94_a.out 2>&1
    grep -aE 'LADDER [0-9]' /data/local/tmp/w94_a.out
    echo "===== B) 触发前先把出厂对照读数落盘 ====="
    cat /proc/ksu_slots > /data/local/tmp/w94_before.txt 2>&1
    chmod 666 /data/local/tmp/w94_before.txt 2>/dev/null
    grep -ao "CFIFIX __arm64_sys_openat[^=]*jt=[0-9a-f]* B->[0-9a-f]*" /data/local/tmp/w94_before.txt | head -2
    echo "===== C) 只改桩：echo 3 > /proc/ksu_fixcfi ====="
    echo 3 > /proc/ksu_fixcfi 2>&1; echo "触发 rc=$?"
    sleep 1
    cat /proc/ksu_slots > /data/local/tmp/w94_after.txt 2>&1
    chmod 666 /data/local/tmp/w94_after.txt 2>/dev/null
    echo "  --- 触发段读数(桩写完复读的是什么) ---"
    sed -n '/ksu_fixcfi 触发/,$p' /data/local/tmp/w94_after.txt | tr '|' '\n' | grep -aE "CFIFIX|跳过|失败|没落地|CFIGUARD" | head -14
    echo "===== D) 复跑同一份阶梯(判据就在这 5 行) ====="
    "$K" grant 10315 >/data/local/tmp/w94_d.out 2>&1
    grep -aE 'LADDER [0-9]|子进程结束' /data/local/tmp/w94_d.out
    echo "===== E) 能 exec 的话，跑一条真命令看看 ====="
    "$K" grant 10315 /system/bin/toybox id >/data/local/tmp/w94_e.out 2>&1
    grep -aE 'LADDER 9|uid=0|uid=10315' /data/local/tmp/w94_e.out | tail -5
    echo "===== F) 正对照：born-root 守护自己跑同一条 ====="
    /system/bin/toybox id
    echo "===== G) 改完之后普通任务还能不能用(整机健康) ====="
    /system/bin/toybox ls /data/local/tmp/ksuctl86 >/dev/null 2>&1; echo "  root 侧 ls rc=$?"
    ls -l /data/local/tmp/w94_d.out | sed 's/^/  /'
    echo "收工 up=$(cut -d' ' -f1 /proc/uptime)"
} >"$L" 2>&1
chmod 666 "$L" /data/local/tmp/w94_a.out /data/local/tmp/w94_d.out /data/local/tmp/w94_e.out 2>/dev/null
