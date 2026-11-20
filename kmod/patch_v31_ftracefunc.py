import io, sys

P = "kmod/ksu_one_stage.sh"
s = io.open(P, encoding="utf-8").read()
NL = chr(10)
Q = chr(34)
SQ = chr(39)
BS = chr(92)


def sub(old, new, tag):
    global s
    if s.count(old) != 1:
        sys.exit("ANCHOR FAIL [%s] count=%d" % (tag, s.count(old)))
    s = s.replace(old, new)
    print("ok [%s]" % tag)


# 上一发的 stacktrace 里，force_sig 之上两格全解析成 __cfi_check ⇒ 只知道"是某个内核
# 函数在 syscall 路径里 force_sig(SIGKILL)"，不知道是谁。function tracer 的每条记录自带
# parent_ip(打印成 `callee <-caller`)⇒ 同一发里顺手把它开上，一次拿全。
sub(
    "        echo 1 > events/signal/signal_generate/enable" + NL
    + "        echo 1 > events/signal/signal_deliver/enable" + NL
    + "        echo 1 > tracing_on" + NL,
    "        echo 1 > events/signal/signal_generate/enable" + NL
    + "        echo 1 > events/signal/signal_deliver/enable" + NL
    + "        : > set_ftrace_filter 2>/dev/null" + NL
    + "        for f in force_sig force_sig_info force_sig_info_to_task arm64_force_sig_fault force_signal_inject do_send_sig_info; do" + NL
    + "            echo " + Q + "$f" + Q + " >> set_ftrace_filter 2>/dev/null" + NL
    + "        done" + NL
    + "        echo function > current_tracer 2>/dev/null" + NL
    + "        echo 1 > tracing_on" + NL,
    "function tracer arm",
)

sub(
    "    log \"             del=[$(cat $FT/events/signal/signal_deliver/filter 2>&1 | tr '" + NL + "' ')] stacktrace=[$(cat $FT/options/stacktrace 2>&1)] buf=$(cat $FT/buffer_size_kb 2>&1)K\"",
    "    log \"             del=[$(cat $FT/events/signal/signal_deliver/filter 2>&1 | tr '" + NL + "' ')] stacktrace=[$(cat $FT/options/stacktrace 2>&1)] buf=$(cat $FT/buffer_size_kb 2>&1)K\"" + NL
    + "    log \"             current_tracer=[$(cat $FT/current_tracer 2>&1)] filter=[$(cat $FT/set_ftrace_filter 2>&1 | tr '" + NL + "' ' ')]\"",
    "report tracer",
)

# dump 里加一段"谁调用了 force_sig"
sub(
    "    log \"  ----- 投递到 suwrootd / app 的那几行 -----\"",
    "    log \"  ----- function tracer: callee <-caller(这一格才是凶手名字) -----\"" + NL
    + "    grep -E 'force_sig|send_sig_info|signal_inject' /data/local/tmp/ksu_ftrace.txt 2>/dev/null | head -25 | sed 's/^/    /'" + NL
    + "    echo nop > $FT/current_tracer 2>/dev/null" + NL
    + "    : > $FT/set_ftrace_filter 2>/dev/null" + NL
    + "    log \"  ----- 投递到 suwrootd / app 的那几行 -----\"",
    "dump caller",
)

sub(
    "log \"=== 起点 v30 stage=",
    "log \"=== 起点 v31 stage=",
    "marker v31",
)

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("written %s bytes=%d" % (P, len(s)))
