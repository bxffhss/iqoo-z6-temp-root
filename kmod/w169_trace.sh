#!/system/bin/sh
# w169_trace.sh —— 给 clone 那条 EPERM **定位到函数**：kretprobe 打返回值，一次跑完就摘掉探针。
#   一手读数(w168)：同一个 escape 任务上 `clone3` 12 格全过(含"0 flag + SIGCHLD"=完整 fork 形状)，
#   而 `__NR_clone`(220) 四格全 EPERM、`setuid`(146)/`setresuid`(147) 也 EPERM，`setgid`/`setreuid`/`getresuid` 正常；
#   窗口是 Permissive、`Seccomp:0`+`filter=0`+`SECCOMP_GET_ACTION_AVAIL` 回 EOPNOTSUPP、`ti_flags` 与能 fork 的 root 任务完全同值。
#   ⇒ 剩下唯一没测的是"那个 -1 是**在哪个函数里**产生的"：
#     有 cp_clone 记录且 ret=-1 ⇒ 进了 `__arm64_sys_clone`，凶手在里面(继续看 _do_fork/copy_process 哪一层先 -1)；
#     **没有**记录 ⇒ 根本没进这个函数 ⇒ 拒在 syscall 入口那一层(表项/厂商入口钩子) —— 这两种解法完全不同。
#   ★tracefs 单独挂到我们自己的目录(这台机 /sys/kernel/debug 不存在)；跑完 enable=0 + 清 kprobe_events。
L=/data/local/tmp/w169_trace.out
CTL=/data/local/tmp/ksuctl88
D=/data/local/tmp/dbg
T=$D/tracing
{
    : >"$L"
    chmod 666 "$L" 2>/dev/null
    exec >>"$L" 2>&1
    echo "=== T up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) enf=$(getenforce)"
    U1=$(cat /data/local/tmp/w168_u1.uid 2>/dev/null | tr -dc '0-9')
    case "$U1" in
        [0-9][0-9][0-9] | [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
        *) echo "[x] U1=[$U1] 不是 uid ⇒ 不跑"; echo "===== DONE"; exit 0 ;;
    esac
    mkdir -p "$D" 2>&1
    echo "  /proc/filesystems 里：$(grep -aE 'tracefs|debugfs' /proc/filesystems 2>/dev/null | tr '
' ' ')"
    if [ ! -e "$D/kprobe_events" ] && [ ! -e "$D/tracing/kprobe_events" ]; then
        mount -t tracefs none "$D" 2>&1
        echo "  mount 之后 /proc/mounts: $(grep -a dbg /proc/mounts 2>/dev/null | tr '
' ' ')"
    fi
    if [ -e "$D/kprobe_events" ]; then
        T=$D                      # tracefs 直接挂在挂载点上：文件就在 $D 下面
    elif [ -e "$D/tracing/kprobe_events" ]; then
        T=$D/tracing              # 走 debugfs 那套布局时的路径
    else
        echo "[x] 挂不上 tracefs ⇒ 这一格作废(回头用 ko 里的 kretprobe)"
        echo "===== DONE"
        exit 0
    fi
    echo "  用的目录 T=$T (kprobe_events=$([ -e $T/kprobe_events ] && echo 有 || echo 没有))"
    echo "  可用探针文件：$(ls $T 2>/dev/null | tr '
' ' ' | cut -c1-200)"
    echo "  这些符号在不在 kallsyms：$(grep -aE ' (__arm64_sys_clone|__arm64_sys_clone3|_do_fork|copy_process|kernel_clone)$' /proc/kallsyms | tr '
' ' ')"
    echo "--- 装三个 kretprobe(只留这一发) ---"
    : >"$T/kprobe_events"
    echo 'r:cp_clone __arm64_sys_clone' >>"$T/kprobe_events" 2>&1
    echo 'r:cp_clone3 __arm64_sys_clone3' >>"$T/kprobe_events" 2>&1
    echo 'r:cp_fork _do_fork' >>"$T/kprobe_events" 2>&1
    echo "  已登记：$(cat $T/kprobe_events 2>/dev/null | tr '\n' ' ')"
    echo 1 >"$T/events/kprobes/cp_clone/enable" 2>&1
    echo 1 >"$T/events/kprobes/cp_clone3/enable" 2>&1
    echo 1 >"$T/events/kprobes/cp_fork/enable" 2>&1
    echo 1 >"$T/tracing_on" 2>&1
    echo 200 >"$T/buffer_size_kb" 2>&1

    echo "--- 先做一次正对照：本任务(能 fork)自己就调用了 ioctl/一堆 syscall ---"
    : >"$T/trace" 2>/dev/null   # 先清空环形缓冲，下面的记录才只属于这一发
    "$CTL" granted "$U1" >/dev/null 2>&1

    echo "--- 现在让 escape 后的任务自己 fork(LADDER 14 就是那一格) ---"
    "$CTL" grant "$U1" 2>&1 | grep -aE "GRANT_ROOT|LADDER (0|1|14) " | cut -c1-150

    echo "--- 内核看到的调用与返回值 ---"
    cat "$T/trace" 2>/dev/null | grep -aE "cp_clone|cp_clone3|cp_fork" | tail -40
    echo "  (计数) cp_clone=$(grep -ac cp_clone: $T/trace 2>/dev/null) cp_clone3=$(grep -ac cp_clone3: $T/trace 2>/dev/null) cp_fork=$(grep -ac cp_fork: $T/trace 2>/dev/null)"
    echo "--- 只看我们这个任务(comm=ksuctl88，LADDER 14 就是在它里面调的) ---"
    grep -a ksuctl88 "$T/trace" 2>/dev/null | tail -30
    echo "  (我们这个任务的记录数) cp_clone=$(grep -a ksuctl88 $T/trace 2>/dev/null | grep -ac cp_clone:) cp_clone3=$(grep -a ksuctl88 $T/trace 2>/dev/null | grep -ac cp_clone3:) cp_fork=$(grep -a ksuctl88 $T/trace 2>/dev/null | grep -ac cp_fork:)"

    echo "--- 摘探针 ---"
    echo 0 >"$T/tracing_on" 2>&1
    echo 0 >"$T/events/kprobes/cp_clone/enable" 2>&1
    echo 0 >"$T/events/kprobes/cp_clone3/enable" 2>&1
    echo 0 >"$T/events/kprobes/cp_fork/enable" 2>&1
    : >"$T/kprobe_events" 2>&1
    echo "  清完：kprobe_events=[$(cat $T/kprobe_events 2>/dev/null)]"
    echo "===== DONE"
} 2>&1
chmod 666 "$L" 2>/dev/null
