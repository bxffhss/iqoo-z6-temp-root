import io, sys

P = "kmod/ksu_one_stage.sh"
s = io.open(P, encoding="utf-8").read()
NL = chr(10)
Q = chr(34)
SQ = chr(39)
BS = chr(92)

i = s.find("ftrace_arm() {")
if i < 0 or s.count("ftrace_arm() {") != 1:
    sys.exit("ANCHOR FAIL: ftrace_arm count=%d" % s.count("ftrace_arm() {"))
j = s.find("# ftrace_dump ", i)
if j < 0:
    sys.exit("ANCHOR FAIL: ftrace_dump 找不到")

NEW = (
    "# v32 的教训(第四十九发)：这一版之前 arm 里写了 `: > set_ftrace_filter`，而那个文件在本机" + NL
    + "#   根本不存在(没编 CONFIG_FUNCTION_TRACER)⇒ **`:` 是 POSIX 特殊内建，它的重定向失败会让" + NL
    + "#   非交互 shell 直接退出** ⇒ 子 shell 当场死，最后一行 `echo 1 > tracing_on` 没跑 ⇒" + NL
    + "#   trace 里 0 条记录(444 字节全是表头)。⇒ 现在：①不碰那个文件；②tracing_on 放最后但" + NL
    + "#   每条都可能失败的写都带 2>/dev/null 且不用 `:`；③挂完立刻回读 tracing_on 自证。" + NL
    + "#" + NL
    + "# ★这一发的正题：force_sig 的 **x30 = 它的返回地址**。上一发的 options/stacktrace 里" + NL
    + "#   force_sig 之上两格只解析成 `__cfi_check`(KCFI 的跳转表：return address 落在跳转表里，" + NL
    + "#   按 kallsyms 查就撞到那个巨型符号头上)⇒ 符号名查不出来。LR 是一个硬数值，谁也糊不了：" + NL
    + "#   同一发里把 /proc/kallsyms 也 dump 下来，回 PC 上按地址区间精确算出是哪个函数。" + NL
    + "ftrace_arm() {" + NL
    + "    if [ ! -d " + Q + "$FT/events/signal" + Q + " ]; then" + NL
    + "        log \"  ftrace: 没有 $FT/events/signal ⇒ 这一发不带信号探针\"" + NL
    + "        return" + NL
    + "    fi" + NL
    + "    (" + NL
    + "        cd " + Q + "$FT" + Q + " || exit" + NL
    + "        echo 6144 > buffer_size_kb 2>/dev/null" + NL
    + "        echo " + Q + "sig == 9" + Q + " > events/signal/signal_generate/filter 2>/dev/null" + NL
    + "        echo " + Q + "comm == " + BS + Q + "suwrootd" + BS + Q + " || comm == " + BS + Q + "com.suw.manager" + BS + Q + Q + " > events/signal/signal_deliver/filter 2>/dev/null" + NL
    + "        echo 1 > options/stacktrace 2>/dev/null" + NL
    + "        echo 1 > events/signal/signal_generate/enable 2>/dev/null" + NL
    + "        echo 1 > events/signal/signal_deliver/enable 2>/dev/null" + NL
    + "        if [ -w kprobe_events ]; then" + NL
    + "            echo " + Q + "p:kpfs force_sig sig=%x0 lr=%x30" + Q + " > kprobe_events 2>/dev/null" + NL
    + "            echo " + Q + "p:kpfi force_sig_info_to_task sig=%x0 lr=%x30" + Q + " >> kprobe_events 2>/dev/null" + NL
    + "            echo " + Q + "p:kpbf arm64_force_sig_fault sig=%x0 lr=%x30" + Q + " >> kprobe_events 2>/dev/null" + NL
    + "            echo " + Q + "p:kpds die" + Q + " >> kprobe_events 2>/dev/null" + NL
    + "            echo 1 > events/kpfs/force_sig/enable 2>/dev/null" + NL
    + "            echo 1 > events/kpfi/force_sig_info_to_task/enable 2>/dev/null" + NL
    + "            echo 1 > events/kpbf/arm64_force_sig_fault/enable 2>/dev/null" + NL
    + "            echo 1 > events/kpds/die/enable 2>/dev/null" + NL
    + "        fi" + NL
    + "        echo 1 > tracing_on" + NL
    + "    )" + NL
    + "    log \"  挂上: gen=[$(cat $FT/events/signal/signal_generate/filter 2>&1 | tr '" + BS + "n' ' ')] kp=[$(cat $FT/kprobe_events 2>&1 | tr '" + BS + "n' ' ' | cut -c1-150)]\"" + NL
    + "    log \"       on=[$(cat $FT/tracing_on 2>&1)] tracer=[$(cat $FT/current_tracer 2>&1)] stacktrace=[$(cat $FT/options/stacktrace 2>&1)] buf=$(cat $FT/buffer_size_kb 2>&1)K\"" + NL
    + "    echo 0 > /proc/sys/kernel/printk_ratelimit 2>/dev/null" + NL
    + "    cat /proc/sys/kernel/tainted > /data/local/tmp/ksu_tainted_before.txt 2>/dev/null" + NL
    + "    cp /proc/kallsyms /data/local/tmp/ksu_kallsyms.txt 2>/dev/null" + NL
    + "    chmod 666 /data/local/tmp/ksu_kallsyms.txt /data/local/tmp/ksu_tainted_before.txt 2>/dev/null" + NL
    + "    sync" + NL
    + "    log \"  kallsyms=$(wc -l < /data/local/tmp/ksu_kallsyms.txt 2>/dev/null) 行 ratelimit=[$(cat /proc/sys/kernel/printk_ratelimit 2>&1)] tainted前=[$(cat /data/local/tmp/ksu_tainted_before.txt 2>/dev/null)] kptr=[$(cat /proc/sys/kernel/kptr_restrict 2>&1)]\"" + NL
    + "    touch /data/local/tmp/ksu_ftrace_armed" + NL
    + "    chmod 666 /data/local/tmp/ksu_ftrace_armed 2>/dev/null" + NL
    + "}" + NL
    + NL
)

s = s[:i] + NEW + s[j:]

# dump 里补 tainted 与 kprobe 行
old = "    log \"  ----- function tracer: callee <-caller(这一格才是凶手名字) -----\"" + NL
if s.count(old) != 1:
    sys.exit("ANCHOR FAIL: dump caller 段 count=%d" % s.count(old))
s = s.replace(
    old,
    "    log \"  ----- kprobe: force_sig 的 sig + LR(返回地址，硬数值) -----\"" + NL
    + "    grep -E 'force_sig|arm64_force_sig_fault|die' /data/local/tmp/ksu_ftrace.txt 2>/dev/null | grep -v 'signal_' | head -25 | sed " + SQ + "s/^/    /" + SQ + NL
    + "    log \"  tainted 后=[$(cat /proc/sys/kernel/tainted 2>&1)] (前=$(cat /data/local/tmp/ksu_tainted_before.txt 2>/dev/null)；TAINT_DIE=bit7⇒+128, TAINT_WARN=bit9⇒+512)\"" + NL
    + "    log \"  ----- 以前这里想开 function tracer：本机没编 CONFIG_FUNCTION_TRACER ⇒ 改走 kprobe+LR -----\"" + NL,
)

sub_old = "log \"=== 起点 v31 stage="
if s.count(sub_old) != 1:
    sys.exit("ANCHOR FAIL: marker")
s = s.replace(sub_old, "log \"=== 起点 v32 stage=")

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("written %s bytes=%d" % (P, len(s)))
