#!/system/bin/sh
# w169b_trace.sh —— 上一发(w169)自己先倒在坑里：`: >"$D/kprobe_events"` 吃 EBUSY，而 `:` 是 **special builtin**，
#   mksh 对它的重定向失败会**直接退出脚本**(POSIX 规定) ⇒ 后面全没跑。这一发改成"只加一条、不 truncate 全部"。
#   顺带把那个 EBUSY 本身当读数读：**要是别人已经在这台机上挂着 kprobe 事件，`kprobe_events`/`enabled_probes` 里就会写着是谁。**
#   目的不变：`__arm64_sys_clone` 到底有没有被"调用并返回 -1"。
#     有记录 ret=-1 ⇒ 进了函数 ⇒ 凶手在 clone/_do_fork/copy_process 里面；
#     完全没有记录 ⇒ 根本没进函数 ⇒ 拒在 syscall 入口那一层(表项被换/入口钩子)。
L=/data/local/tmp/w169b.out
D=/data/local/tmp/dbg
CTL=/data/local/tmp/ksuctl88
{
    : >"$L"
    chmod 666 "$L" 2>/dev/null
    exec >>"$L" 2>&1
    echo "=== B up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) enf=$(getenforce)"
    U1=$(cat /data/local/tmp/w168_u1.uid 2>/dev/null | tr -dc '0-9')
    case "$U1" in
        [0-9][0-9][0-9] | [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
        *) echo "[x] U1=[$U1] 不是 uid ⇒ 不跑"; echo "===== DONE"; exit 0 ;;
    esac
    [ -e "$D/kprobe_events" ] || { mkdir -p "$D" 2>&1; mount -t tracefs none "$D" 2>&1; }
    [ -e "$D/kprobe_events" ] || { echo "[x] 还是没 tracefs ⇒ 这一格作废"; echo "===== DONE"; exit 0; }
    echo "--- 这台机上现在谁在用 kprobe 事件(把 EBUSY 当读数) ---"
    echo "  kprobe_events=[$(cat $D/kprobe_events 2>&1 | tr '\n' ' ')]"
    echo "  enabled_probes=[$(cat $D/enabled_probes 2>&1 | tr '\n' ' ' | cut -c1-400)]"
    echo "  current_tracer=[$(cat $D/current_tracer 2>&1)] tracing_on=[$(cat $D/tracing_on 2>&1)]"
    echo "  events 下有哪些族: $(ls $D/events 2>&1 | tr '\n' ' ')"
    echo "  error_log 尾巴: $(tail -6 $D/error_log 2>&1 | tr '\n' '|')"
    echo "  /proc/sys/kernel/ftrace_enabled=$(cat /proc/sys/kernel/ftrace_enabled 2>&1)"

    echo "--- 只加一条 kretprobe：r:cpq __arm64_sys_clone ---"
    echo 'r:cpq __arm64_sys_clone' >>"$D/kprobe_events" 2>&1
    echo "  注册后 kprobe_events=[$(cat $D/kprobe_events 2>&1 | tr '\n' ' ')]"
    if [ ! -e "$D/events/kprobes/cpq/enable" ]; then
        echo "[x] 没注册上(看上面的 error_log / 注册回执) ⇒ 这一格作废"
        echo "===== DONE"; exit 0
    fi
    echo 1 >"$D/events/kprobes/cpq/enable" 2>&1
    echo 800 >"$D/buffer_size_kb" 2>&1
    echo 1 >"$D/tracing_on" 2>&1
    echo 0 >"$D/trace" 2>&1
    echo "--- 正对照：本任务(sh)自己 fork 一次(kill -0 自己不要 fork；这里跑一条外部命令走一次真 fork) ---"
    false
    echo "  sh 的 cpq 记录数=$(grep -a ' cpq:' $D/trace 2>/dev/null | grep -ac 'sh-')"
    echo "--- 实验：让 escape 后的任务(ksuctl88)调 fork ---"
    "$CTL" grant "$U1" 2>&1 | grep -aE "GRANT_ROOT|LADDER 14" | cut -c1-140
    echo "--- trace 里与这个任务有关的全部行 ---"
    grep -a ksuctl88 "$D/trace" 2>/dev/null | tail -25
    echo "  (计数) 本任务的 cpq 命中=$(grep -a ksuctl88 $D/trace 2>/dev/null | grep -ac ' cpq:')"
    echo "  全表 cpq 命中(别人的也算)= $(grep -ac ' cpq:' $D/trace 2>/dev/null)"
    echo "--- 摘探针 ---"
    echo 0 >"$D/events/kprobes/cpq/enable" 2>&1
    echo '-:cpq' >>"$D/kprobe_events" 2>&1
    echo "  摘完 kprobe_events=[$(cat $D/kprobe_events 2>&1 | tr '\n' ' ')]"
    echo 0 >"$D/tracing_on" 2>&1
    echo "===== DONE"
} 2>&1
chmod 666 "$L" 2>/dev/null
