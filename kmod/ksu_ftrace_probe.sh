#!/system/bin/sh
# ksu_ftrace_probe —— 塞进 ksu_module_apply.sh 这个"root 执行载体"里跑的临时探针。
# 目的只有一个：钉死那个 SIGKILL 是谁生成的(signal_generate 的 comm/pid 是**发送方**，
# signal_deliver 的是**接收方**)，并对每个事件挂上内核栈 ⇒ 栈里那个函数名就是答案。
L=/data/local/tmp/ksu_ftrace.log
T=/sys/kernel/tracing
[ -d "$T" ] || T=/sys/kernel/debug/tracing
: > "$L" 2>/dev/null
chmod 666 "$L" 2>/dev/null
say() {
    echo "[probe] $*" >> "$L"
    sync
}

say "起点 uid=$(id -u) T=$T"
if [ ! -d "$T/events/signal" ]; then
    say "没有 $T/events/signal ⇒ 这个 boot 上 ftrace 用不了，收工"
    exit 0
fi

cd "$T" || exit 1
echo 0 > tracing_on
: > trace
echo 6144 > buffer_size_kb 2>/dev/null
say "buffer_size_kb=$(cat buffer_size_kb 2>&1)"

# 只看 SIGKILL；signal_generate 里没有"接收方"字段，所以不能按 comm 过滤(那过滤的是发送方)
echo 'sig == 9' > events/signal/signal_generate/filter 2>>"$L"
echo 'comm == "suwrootd" || comm == "suwprobe"' > events/signal/signal_deliver/filter 2>>"$L"
echo 1 > options/stacktrace 2>>"$L"
say "filter gen=[$(cat events/signal/signal_generate/filter 2>&1 | tr '\n' ' ')]"
say "filter del=[$(cat events/signal/signal_deliver/filter 2>&1 | tr '\n' ' ')]"
say "options/stacktrace=[$(cat options/stacktrace 2>&1)]"

echo 1 > events/signal/signal_generate/enable
echo 1 > events/signal/signal_deliver/enable
echo 1 > tracing_on
say "tracing_on=$(cat tracing_on 2>&1) —— 现在可以触发 app 了"
touch /data/local/tmp/ksu_ftrace_armed
chmod 666 /data/local/tmp/ksu_ftrace_armed 2>/dev/null

i=0
while [ $i -lt 75 ]; do
    sleep 1
    i=$((i + 1))
    if [ $i -eq 25 ]; then
        cat trace > /data/local/tmp/ksu_ftrace_p1.txt 2>/dev/null
        chmod 666 /data/local/tmp/ksu_ftrace_p1.txt 2>/dev/null
        sync
        say "25s 快照 $(wc -l < /data/local/tmp/ksu_ftrace_p1.txt 2>/dev/null) 行"
    fi
done

cat trace > /data/local/tmp/ksu_ftrace.txt 2>/dev/null
chmod 666 /data/local/tmp/ksu_ftrace.txt 2>/dev/null
sync
say "收尾：trace $(wc -c < /data/local/tmp/ksu_ftrace.txt 2>/dev/null) 字节 / $(wc -l < /data/local/tmp/ksu_ftrace.txt 2>/dev/null) 行"
echo 0 > tracing_on
echo 0 > events/signal/signal_generate/enable
echo 0 > events/signal/signal_deliver/enable
echo 0 > options/stacktrace 2>/dev/null
say "探针结束(没被杀)"
