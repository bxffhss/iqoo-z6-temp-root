#!/system/bin/sh
# 窗口 87 第二格：**把探针的 filter 改对**，再问一次"EPERM 是在 syscall 之内还是之前给的"。
# 为什么这一格必须重做：第八十发那条"三条 kretprobe 全部零命中 ⇒ EPERM 发生在进 __arm64_sys_execve
#   之前"的结论，探针 filter 写的是 `comm == "suwrootd" || comm == "KSU_EXEC"`，
#   而当场真正在 exec/open 的任务 comm 是 **ksuctl**(第八十六发一手) ⇒ 零命中是筛子的必然结果，
#   不是证据(记忆"防刷屏的筛子把我们要找的那一例吃掉了")。第二发又发现环形缓冲被自己的
#   fpsimd_save+stacktrace 刷到翻了 20 遍 ⇒ 两个方向都会假阴。
# 这次的做法：① 先把噪声源关掉(fpsimd_save / 我们的控制探针 / stacktrace)，
#   ② 只留两条**无参数、comm 过滤正确**的返回探针，③ 缓冲开到 2048K/cpu，④ 跑阶梯，⑤ 立刻抓 trace。
# 判据(三态，别只看一态)：
#   看到 `ksuctl86-xxxx oa: (__arm64_sys_openat+0x...) ret=-1` ⇒ 拦在 syscall **之内**(往下找具体函数)
#   一条都没有、而阶梯照样报 EPERM ⇒ 拦在派发**之前**(那就是 el0_svc 层的改道/别的机制)
#   阶梯这次没报 EPERM ⇒ 上一发的现象不可复现，先修现象再谈机理。
L=/data/local/tmp/w87_trace.out
T=/sys/kernel/tracing
[ -d "$T" ] || T=/sys/kernel/debug/tracing
{
    cd "$T" || exit 1
    echo "T=$T up=$(cut -d' ' -f1 /proc/uptime)"
    echo 0 >tracing_on
    echo >events/enable 2>/dev/null
    echo >kprobe_events 2>/dev/null
    echo 0 >options/stacktrace 2>/dev/null
    echo 2048 >buffer_size_kb 2>/dev/null
    echo "清场后 kprobe_events=[$(cat kprobe_events | tr '\n' ' ')]"
    ERR1=$(echo 'r16:k9/oa __arm64_sys_openat ret=$retval:x32' >>kprobe_events 2>&1)
    ERR2=$(echo 'r16:k9/xv __arm64_sys_execve ret=$retval:x32' >>kprobe_events 2>&1)
    echo "注册 oa:[$ERR1] xv:[$ERR2]  现况=[$(cat kprobe_events | tr '\n' ' ')]"
    for e in oa xv; do
        echo "comm == \"ksuctl86\"" >"events/k9/$e/filter" 2>&1
        echo 1 >"events/k9/$e/enable" 2>&1
        echo "  $e enable=$(cat events/k9/$e/enable 2>&1) filter=[$(cat events/k9/$e/filter 2>&1)]"
    done
    echo >trace
    echo 1 >tracing_on
    echo "===== 跑阶梯(comm=ksuctl86) ====="
    /data/local/tmp/ksuctl86 grant 10315 >/data/local/tmp/w87_ladder.out 2>&1
    echo "阶梯 rc=$?"
    grep -aE 'LADDER [0-9]' /data/local/tmp/w87_ladder.out
    sleep 1
    echo 0 >tracing_on
    echo "===== 探针抓到了什么 ====="
    echo "oa 命中=$(grep -ac 'k9:oa' trace)  xv 命中=$(grep -ac 'k9:xv' trace)"
    grep -a 'k9:' trace | tail -25
    echo "===== 阶梯那份 errno 的原文(前 12 行) ====="
    head -12 /data/local/tmp/w87_ladder.out
    echo "===== 收尾：把探针拆干净，别留给下一发当噪声 ====="
    echo 0 >events/k9/enable 2>/dev/null
    echo >kprobe_events 2>/dev/null
    echo 1 >tracing_on
    echo "收工 up=$(cut -d' ' -f1 /proc/uptime)"
} >"$L" 2>&1
chmod 666 "$L" /data/local/tmp/w87_ladder.out 2>/dev/null
