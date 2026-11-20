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


# ── 1) 版本行 + 起点行 ────────────────────────────────────────────────
sub(
    "# ksu_one_stage.sh v29 —— v28 + 窗口内模块 runner(md §6.62)；此前修正：" + NL,
    "# ksu_one_stage.sh v30 —— v29.1 + **信号探针提前**(md §6.65)：" + NL
    + "#   第四十七发的教训：窗口从 insmod 起只有 ~3.5 分钟，而 ftrace 探针当时挂在最末尾的" + NL
    + "#   " + Q + "模块战线 runner" + Q + "里 ⇒ 机器在它跑到之前就复位了，等于没挂。" + NL
    + "#   ⇒ 现在：判据④之前挂 signal_generate/signal_deliver + stacktrace，拿到 armed 报告后" + NL
    + "#     立刻落盘；模块战线仍在最后(它已经复现过两次，掉一发不心疼)。" + NL
    + "#   顺带：外部证据那段等的 pattern 是" + Q + "子进程 pid=" + Q + "，而 v30 的 JNI 黑匣子印的是" + NL
    + "#   " + Q + "子进程 5573 被信号 9 杀死" + Q + " ⇒ 永远等不到，白烧 90s 窗口，一并修。" + NL
    + "# ksu_one_stage.sh v29 —— v28 + 窗口内模块 runner(md §6.62)；此前修正：" + NL,
    "header",
)

sub(
    "log \"=== 起点 v29.1 stage=$S args=[$ARGS] extra=[$EXTRA] dom=$DOM up=$(upt) ===\"",
    "log \"=== 起点 v30 stage=$S args=[$ARGS] extra=[$EXTRA] dom=$DOM up=$(upt) ===\"",
    "marker",
)

# ── 2) 探针函数(挂在 upt() 后面) ──────────────────────────────────────
FT = "FT=/sys/kernel/tracing"
ARM = (
    NL
    + FT + NL
    + "[ -d " + Q + "$FT/events/signal" + Q + " ] || FT=/sys/kernel/debug/tracing" + NL
    + NL
    + "# ftrace_arm —— 把" + Q + "谁在杀我的 root 子进程" + Q + "这个问题交给内核自己回答。" + NL
    + "#   signal_generate 记录里的 comm/pid 是**发送方**(事件在发送方上下文里打)，" + NL
    + "#   signal_deliver 里的才是接收方 ⇒ 两个都开：前者给" + Q + "谁发的" + Q + "，后者给" + NL
    + "#   " + Q + "什么时候真落到 suwrootd 头上、si_code 是多少" + Q + "。options/stacktrace 让每个事件" + NL
    + "#   带一段内核栈 ⇒ 栈里那个函数名就是凶手(厂商反 root？memcg？seccomp？)。" + NL
    + "ftrace_arm() {" + NL
    + "    if [ ! -d " + Q + "$FT/events/signal" + Q + " ]; then" + NL
    + "        log \"  ftrace: 没有 $FT/events/signal ⇒ 这一发不带信号探针\"" + NL
    + "        return" + NL
    + "    fi" + NL
    + "    (" + NL
    + "        cd " + Q + "$FT" + Q + " || exit" + NL
    + "        echo 0 > tracing_on" + NL
    + "        : > trace" + NL
    + "        echo 6144 > buffer_size_kb 2>/dev/null" + NL
    + "        echo " + Q + "sig == 9" + Q + " > events/signal/signal_generate/filter 2>/dev/null" + NL
    + "        echo " + Q + "comm == " + BS + Q + "suwrootd" + BS + Q + " || comm == " + BS + Q + "com.suw.manager" + BS + Q + Q + " > events/signal/signal_deliver/filter 2>/dev/null" + NL
    + "        echo 1 > options/stacktrace 2>/dev/null" + NL
    + "        echo 1 > events/signal/signal_generate/enable" + NL
    + "        echo 1 > events/signal/signal_deliver/enable" + NL
    + "        echo 1 > tracing_on" + NL
    + "    )" + NL
    + "    log \"  ftrace 已挂上: gen=[$(cat $FT/events/signal/signal_generate/filter 2>&1 | tr " + SQ + NL + SQ + " " + SQ + ")]\"" + NL
    + "    log \"             del=[$(cat $FT/events/signal/signal_deliver/filter 2>&1 | tr " + SQ + NL + SQ + " " + SQ + ")] stacktrace=[$(cat $FT/options/stacktrace 2>&1)] buf=$(cat $FT/buffer_size_kb 2>&1)K\"" + NL
    + "    touch /data/local/tmp/ksu_ftrace_armed; chmod 666 /data/local/tmp/ksu_ftrace_armed 2>/dev/null" + NL
    + "}" + NL
    + NL
    + "# ftrace_dump —— 立刻落盘：这个 boot 随时可能没，trace 只在内存里等于没有。" + NL
    + "ftrace_dump() {" + NL
    + "    (" + NL
    + "        cd " + Q + "$FT" + Q + " 2>/dev/null || exit" + NL
    + "        cat trace > /data/local/tmp/ksu_ftrace.txt" + NL
    + "        echo 0 > tracing_on" + NL
    + "        echo 0 > events/signal/signal_generate/enable" + NL
    + "        echo 0 > events/signal/signal_deliver/enable" + NL
    + "        echo 0 > options/stacktrace 2>/dev/null" + NL
    + "    )" + NL
    + "    chmod 666 /data/local/tmp/ksu_ftrace.txt 2>/dev/null" + NL
    + "    log \"  ftrace 落盘 $(wc -c < /data/local/tmp/ksu_ftrace.txt 2>/dev/null) 字节 / $(wc -l < /data/local/tmp/ksu_ftrace.txt 2>/dev/null) 行\"" + NL
    + "    log \"  ----- SIGKILL 生成点(发送方 comm/pid + 内核栈) -----\"" + NL
    + "    grep -A14 -E " + SQ + "signal_generate.*sig=9" + SQ + " /data/local/tmp/ksu_ftrace.txt 2>/dev/null | head -70 | sed " + SQ + "s/^/    /" + SQ + NL
    + "    log \"  ----- 投递到 suwrootd / app 的那几行 -----\"" + NL
    + "    grep -E " + SQ + "signal_deliver" + SQ + " /data/local/tmp/ksu_ftrace.txt 2>/dev/null | head -20 | sed " + SQ + "s/^/    /" + SQ + NL
    + "    sync" + NL
    + "}" + NL
)

sub(
    "upt() { cut -d" + SQ + " " + SQ + " -f1 /proc/uptime; }" + NL,
    "upt() { cut -d" + SQ + " " + SQ + " -f1 /proc/uptime; }" + NL + ARM,
    "probe funcs",
)

# ── 3) 判据④之前挂探针 ───────────────────────────────────────────────
sub(
    "    APP_PID=$(pidof $PKG | cut -d' ' -f1)" + NL
    + "    log \"===== 判据④",
    "    log \"===== 信号探针(必须在 app 触发之前挂，杀发生在触发之后) =====\"" + NL
    + "    ftrace_arm" + NL
    + "    APP_PID=$(pidof $PKG | cut -d' ' -f1)" + NL
    + "    log \"===== 判据④",
    "arm before trigger",
)

# ── 4) 外部证据：等 pattern 修好 + 从 90s 缩到 12s ────────────────────
old_wait = (
    "    w=0" + NL
    + "    while [ $w -lt 30 ]; do" + NL
    + "        grep -q '子进程 pid=' \"$APP_REPORT\" 2>/dev/null && break" + NL
    + "        w=$((w + 1)); sleep 3" + NL
    + "    done" + NL
)
new_wait = (
    "    w=0" + NL
    + "    while [ $w -lt 6 ]; do" + NL
    + "        grep -q '父进程侧: 子进程' \"$APP_REPORT\" 2>/dev/null && break" + NL
    + "        w=$((w + 1)); sleep 2" + NL
    + "    done" + NL
)
sub(old_wait, new_wait, "wait pattern")

sub(
    "    log \"  等 armed 版报告用了 $((w * 3))s (报告 $(wc -c < \"$APP_REPORT\" 2>/dev/null) 字节)\"",
    "    log \"  等 armed 版报告用了 $((w * 2))s (报告 $(wc -c < \"$APP_REPORT\" 2>/dev/null) 字节)\"",
    "wait log",
)

sub(
    "    KIDP=$(grep -oE '子进程 pid=[0-9]+' \"$APP_REPORT\" 2>/dev/null | head -1 | cut -d= -f2)",
    "    KIDP=$(grep -oE '子进程 (pid=)?[0-9]+' \"$APP_REPORT\" 2>/dev/null | head -1 | grep -oE '[0-9]+')",
    "kidp pattern",
)

# ── 5) 拿到 armed 报告后马上落盘 trace ───────────────────────────────
sub(
    "    log \"----- 子进程产物：模块能不能用 root 跑命令就看 suw_cmd.out 这一格 -----\"",
    "    log \"===== 信号探针落盘(趁 boot 还在) =====\"" + NL
    + "    ftrace_dump" + NL
    + "    log \"----- 子进程产物：模块能不能用 root 跑命令就看 suw_cmd.out 这一格 -----\"",
    "dump after evidence",
)

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("written %s bytes=%d" % (P, len(s)))
