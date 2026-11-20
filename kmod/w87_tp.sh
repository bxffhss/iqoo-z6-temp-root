#!/system/bin/sh
# 窗口 87 第三格：把"拦在派发链的哪一段"钉死。
# 已知(第八十七发一手)：两条探针(入口 p:kpf/oa、返回 r16:k9/oa，filter 已改对 comm=ksuctl86)
#   都零命中，而同一段时间里别的任务(grep)命中了 119802 次 ⇒ **我们这个 escape 过的任务
#   根本没进 __arm64_sys_openat**，可用户态照样拿到 EPERM。
# 现在用 arm64 派发链上**更早**的两个点来二选一：
#   raw_syscalls:sys_enter  —— 在 el0_svc_common 里、invoke_syscall **之前**由 tracepoint 打
#   raw_syscalls:sys_exit   —— 在返回用户态之前打，带 ret
# 判据(三态)：
#   A) 有 sys_enter(id=56) 且 sys_exit ret=-1  ⇒ 拦在 tracepoint 之后、syscall 函数之前
#      (那就是 invoke_syscall / CFI 跳表 / el0_svc_common 里厂商加的那一段)
#   B) 连 sys_enter 都没有                     ⇒ 拦得更早(syscall 号被改/入口被换)，
#      但注意 sys_enter 本身要 TIF_SYSCALL_WORK 才走 ⇒ 单靠它不能定死，需要配合 C
#   C) 阶梯这次没报 EPERM                     ⇒ 现象不可复现，先修现象
L=/data/local/tmp/w87_tp.out
T=/sys/kernel/tracing
[ -d "$T" ] || T=/sys/kernel/debug/tracing
{
    cd "$T" || exit 1
    echo "T=$T up=$(cut -d' ' -f1 /proc/uptime)"
    echo "raw_syscalls 组在不在: $(ls events/ 2>/dev/null | grep -a raw)"
    echo 0 >tracing_on
    echo >trace
    echo 2048 >buffer_size_kb 2>/dev/null
    echo "buffer_size_kb=$(cat buffer_size_kb)"
    for e in sys_enter sys_exit; do
        ERR=$(echo 1 >"events/raw_syscalls/$e/enable" 2>&1)
        FERR=$(echo 'comm == "ksuctl86"' >"events/raw_syscalls/$e/filter" 2>&1)
        echo "  $e en=[$(cat events/raw_syscalls/$e/enable 2>&1)] f=[$(cat events/raw_syscalls/$e/filter 2>&1)] err=[$ERR$FERR]"
    done
    echo 1 >tracing_on
    echo "===== 跑阶梯 ====="
    /data/local/tmp/ksuctl86 grant 10315 >/data/local/tmp/w87_ladder2.out 2>&1
    echo "阶梯 rc=$?"
    grep -aE 'LADDER [0-9]|GRANT_ROOT' /data/local/tmp/w87_ladder2.out
    sleep 1
    echo 0 >tracing_on
    echo "===== trace 里本次的 syscall(前 40 行，含 nr 与 ret) ====="
    grep -a 'raw_syscalls' trace | head -40
    echo "--- 计数: enter=$(grep -ac 'sys_enter' trace) exit=$(grep -ac 'sys_exit' trace)"
    echo "--- 只看 openat(56)/execve(221)/execveat(281)/statx(291)/getpid(172)/socket(198):"
    grep -aE 'id = (56|221|281|291|172|198)' trace | head -20
    echo "===== 正对照：不带 filter 时 sys_enter 有没有在动(证明事件本身是活的) ====="
    echo 'comm == "grep"' >events/raw_syscalls/sys_enter/filter 2>&1
    echo 1 >tracing_on; sleep 1; echo 0 >tracing_on
    echo "  grep 的 enter 行数=$(grep -ac 'sys_enter' trace)"
    for e in sys_enter sys_exit; do echo 0 >"events/raw_syscalls/$e/enable" 2>/dev/null; echo > "events/raw_syscalls/$e/filter" 2>/dev/null; done
    echo 1 >tracing_on
    echo "收工 up=$(cut -d' ' -f1 /proc/uptime)"
} >"$L" 2>&1
chmod 666 "$L" /data/local/tmp/w87_ladder2.out 2>/dev/null
