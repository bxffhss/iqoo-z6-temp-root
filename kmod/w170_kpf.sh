#!/system/bin/sh
# w170_kpf.sh —— 上一发(w169b)在 tracefs 里**撞见了别人的探针**：
#   p:kpf0/oa __arm64_sys_openat / p:kpf/fi force_sig_info_to_task / p:kpf/bf arm64_force_sig_fault /
#   p:kpf/fj force_signal_inject / (失败的一条 r:kpf/xbc do_execveat_common ret=$retval:x32)
#   —— 而我们量到的 EPERM 恰好落在 openat/execve/clone/setuid/setresuid 这一族上。
#   这一发做三件事：
#     A) 把这份"别人装了哪些 kprobe"读**全**(不截断)，并看它们开没开、属于哪个模块；
#     B) 用带 `ret=$retval` 的 kretprobe 把 clone 的 -1 **定位到函数**(__arm64_sys_clone / _do_fork / copy_process 谁先出 -1)；
#     C) 全过程只加自己的事件，跑完立刻摘掉(不 truncate 别人的表)。
L=/data/local/tmp/w170.out
D=/data/local/tmp/dbg
CTL=/data/local/tmp/ksuctl88
{
    : >"$L"
    chmod 666 "$L" 2>/dev/null
    exec >>"$L" 2>&1
    echo "=== K up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) enf=$(getenforce)"
    U1=$(cat /data/local/tmp/w168_u1.uid 2>/dev/null | tr -dc '0-9')
    case "$U1" in
        [0-9][0-9][0-9] | [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
        *) echo "[x] U1=[$U1] 不是 uid ⇒ 不跑"; echo "===== DONE"; exit 0 ;;
    esac
    [ -e "$D/kprobe_events" ] || { mkdir -p "$D" 2>&1; mount -t tracefs none "$D" 2>&1; }
    [ -e "$D/kprobe_events" ] || { echo "[x] 没 tracefs"; echo "===== DONE"; exit 0; }

    echo "===== A) 别人在这台机上装的 kprobe(完整，一行一条) ====="
    cat "$D/kprobe_events" 2>&1
    echo "  -- 事件分组 --"
    ls "$D/events" 2>/dev/null | grep -aiE "kpf|kp|vr|vivo|guard|monit|sec" | head -20
    for g in $D/events/kpf*; do
        [ -d "$g" ] || continue
        echo "  组 $(basename $g): enable=$(cat $g/enable 2>/dev/null) 里面条目=$(ls $g 2>/dev/null | tr '\n' ' ')"
        for e in $g/*; do
            [ -f "$e/enable" ] && echo "    $(basename $e): enable=$(cat $e/enable 2>/dev/null) filter=[$(cat $e/filter 2>/dev/null)]"
        done
    done
    echo "  -- 谁在册：/proc/modules 里可疑的名字 --"
    cut -d' ' -f1 /proc/modules 2>/dev/null | grep -aiE "kpf|guard|monit|vr|vivo|sec|protect|integrity" | head -20
    echo "  -- 模块总数=$(grep -ac . /proc/modules 2>/dev/null) --"
    echo "  -- kallsyms 里带 kpf 的符号(最后那列是归属模块) --"
    grep -ai "kpf" /proc/kallsyms 2>/dev/null | head -8
    echo "  -- error_log 里失败过的注册(能看出对方原本还想探哪些符号) --"
    grep -a "Command:" "$D/error_log" 2>/dev/null | tail -12

    echo "===== B) 把 clone 的 -1 定位到函数 ====="
    for p in 'r:qz1 __arm64_sys_clone ret=$retval' 'r:qz2 _do_fork ret=$retval' 'r:qz3 copy_process ret=$retval'; do
        echo "$p" >>"$D/kprobe_events" 2>&1
        echo "  加 [$p] rc=$?"
    done
    echo 800 >"$D/buffer_size_kb" 2>&1
    for g in qz1 qz2 qz3; do
        [ -e "$D/events/kprobes/$g/enable" ] && { echo 1 >"$D/events/kprobes/$g/enable" 2>&1; echo "  开了 $g"; }
    done
    echo 1 >"$D/tracing_on" 2>&1
    echo 0 >"$D/trace" 2>&1
    echo "--- 正对照：本任务(sh)自己 fork 两次 ---"
    false
    false
    echo "  sh 的记录：$(grep -a ' sh-' $D/trace 2>/dev/null | grep -aE 'qz[123]:' | tail -6)"
    echo "--- 实验：escape 后的任务 fork(期望 LADDER 14 = EPERM) ---"
    "$CTL" grant "$U1" 2>&1 | grep -aE "GRANT_ROOT|LADDER 14" | cut -c1-140
    echo "--- 这个任务的全部 qz 记录(有 ret= 就是进了函数；一条都没有=没进) ---"
    grep -a ksuctl88 "$D/trace" 2>/dev/null | grep -aE 'qz[123]:' | tail -20
    echo "  (计数) qz1_clone=$(grep -a ksuctl88 $D/trace 2>/dev/null | grep -ac ' qz1:') qz2__do_fork=$(grep -a ksuctl88 $D/trace 2>/dev/null | grep -ac ' qz2:') qz3_copy_process=$(grep -a ksuctl88 $D/trace 2>/dev/null | grep -ac ' qz3:')"
    echo "--- 顺带：这个任务在 escape 前后有没有被别人的 oa(openat) 探针记到 ---"
    grep -a ksuctl88 "$D/trace" 2>/dev/null | grep -ac ' oa:' | sed 's/^/  oa 记录数=/'
    echo "--- 摘掉我们加的三条 ---"
    for g in qz1 qz2 qz3; do
        [ -e "$D/events/kprobes/$g/enable" ] && echo 0 >"$D/events/kprobes/$g/enable" 2>&1
        echo "-:$g" >>"$D/kprobe_events" 2>&1
    done
    echo 0 >"$D/tracing_on" 2>&1
    echo "  摘完，我们自己的条目应该没了：$(cat $D/kprobe_events 2>/dev/null | grep -ac qz)"
    echo "===== DONE"
} 2>&1
chmod 666 "$L" 2>/dev/null
