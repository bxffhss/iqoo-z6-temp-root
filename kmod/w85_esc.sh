#!/system/bin/sh
# 第八十五发(窗口 85)：把"escape 变 uid0 之后 open 拿 EPERM"这一格钉死到机理层。
# 要分开的三种可能：
#   (a) 我们自己的 escape 副作用(setup_mount_ns 把 /data 换掉了 / cred 换坏了)
#   (b) 厂商守卫按"任务血统"拦(那 open/exec 都该拦，且与 ns 无关)
#   (c) seccomp 在派发前就 RET_ERRNO(那 syscall 函数根本进不去)
# 每一格都留一手证据：mountinfo 行数差、Seccomp 字段、attr/current、以及"预开 fd 之后还读不读得动"。
LOG=/data/local/tmp/w85_esc.out
PFD=/data/local/tmp/w85_passfd.out
{
    echo "起点 up=$(cut -d' ' -f1 /proc/uptime)"
    echo "===== ① 起 passfd(子进程 grant 完会持续 14s 每秒 open 一次，errno 打在 $PFD) ====="
    /data/local/tmp/ksuctl passfd 10315 14 >"$PFD" 2>&1 &
    CP=$!
    sleep 4
    echo "===== ② 趁它还活着，从外面读它的 /proc(第三个来源，不靠它自报) ====="
    for p in $(pidof ksuctl); do
        echo "--- pid=$p"
        grep -aE '^(Uid|Gid|Seccomp|Seccomp_filters|CapEff|Nspid|TracerPid|PPid)' /proc/$p/status 2>&1 | tr '\n' ' '
        echo
        echo "  attr/current=[$(cat /proc/$p/attr/current 2>&1)]"
        echo "  cwd=[$(ls -l /proc/$p/cwd 2>&1 | sed 's/.*-> //')]"
        echo "  mountinfo: 自己=$(wc -l < /proc/$p/mountinfo 2>/dev/null) 对比 pid1=$(wc -l < /proc/1/mountinfo 2>/dev/null) 本脚本=$(wc -l < /proc/self/mountinfo 2>/dev/null)"
        echo "  root=[$(ls -l /proc/$p/root 2>&1 | sed 's/.*-> //')]"
        echo "  它的 fd 表: $(ls /proc/$p/fd 2>&1 | tr '\n' ' ')"
    done
    echo "===== ③ 等子进程自己把那 14 行 open 结果写完 ====="
    wait $CP
    cat "$PFD"
    echo "===== ④ 对照：born-root 的本脚本自己 open 同一个文件 ====="
    echo "born-root open=$(dd if=/data/local/tmp/ksuctl_hold.out bs=1 count=1 2>&1 | head -c 60)"
    ls -l /data/local/tmp/ksuctl_hold.out 2>&1
    stat -c '%A %U:%G %i %T' /data/local/tmp 2>&1
    echo "收工 up=$(cut -d' ' -f1 /proc/uptime)"
} >"$LOG" 2>&1
chmod 666 "$LOG" "$PFD" 2>/dev/null
