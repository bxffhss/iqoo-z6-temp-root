#!/system/bin/sh
# 窗口 86 第三格：找出"open/execve 一律 EPERM"这一拦的**落点**。
# 已排除：sys_call_table(槽里是原值)、LSM 钩子链(只有 capability/selinux)、seccomp(Seccomp:0)、
#   mount ns(与 pid1 同一份 171 条)、SELinux(当场宽容，且它只会给 EACCES)、livepatch(tainted=4612
#   = OOT|WARN|CPU_OUT_OF_SPEC，没有 TAINT_LIVEPATCH 位)。
# ⇒ 剩下的可能只有"代码被就地打了补丁"：kprobe/kretprobe(arm64 用 BRK) 或 ftrace record。
#   这两种都在 tracing/debugfs 里留名，root 读得到。
L=/data/local/tmp/w86_hook.out
T=/sys/kernel/tracing
[ -d "$T" ] || T=/sys/kernel/debug/tracing
{
    echo "起点 up=$(cut -d' ' -f1 /proc/uptime)  T=$T"
    echo "===== ① ftrace: 哪些函数身上有生效的 record(厂商就地打补丁会留在这) ====="
    for f in enabled_functions available_filter_functions; do
        if [ -r "$T/$f" ]; then
            echo "--- $f 里带 enable/星号 的条目(只看 open/exec/creds 相关):"
            grep -aiE 'open|exec|bprm|filp|lookup_creds|prepare_creds|commit_creds' "$T/$f" 2>/dev/null | grep -aE '\*|enable| \*' | head -25
            echo "    ($f 总行数=$(wc -l < "$T/$f"))"
        else
            echo "--- $f 读不到: $(ls -l $T/$f 2>&1)"
        fi
    done
    echo "  current_tracer=[$(cat $T/current_tracer 2>&1)]  ftrace_enabled=[$(cat /proc/sys/kernel/ftrace_enabled 2>&1)]"
    echo "===== ② debugfs 挂不挂得上(kprobes/list 在这里) ====="
    mkdir -p /data/local/tmp/dbg 2>/dev/null
    mount -t debugfs none /data/local/tmp/dbg 2>&1
    echo "--- kprobes/list:"
    cat /data/local/tmp/dbg/kprobes/list 2>&1 | head -25
    echo "--- kprobes/list 里 open/exec 相关:"
    grep -aiE 'open|exec|bprm' /data/local/tmp/dbg/kprobes/list 2>/dev/null | head -15
    echo "===== ③ 我们自己挂了哪些探针(要把噪声摘干净，别把自伤当证据) ====="
    cat $T/kprobe_events 2>&1 | head -20
    echo "===== ④ 模块表：vr 之外还有谁可疑(名字里带 guard/root/anti 的) ====="
    lsmod 2>/dev/null | awk '{print $1, $2}' | grep -aviE 'kernelsu' | head -60
    echo "===== ⑤ /proc/sys/kernel/tainted 与 modules 顺序里的 vr 基址 ====="
    echo "tainted=$(cat /proc/sys/kernel/tainted)"
    grep -a ' vr ' /proc/modules 2>&1 | head -2
    echo "收工 up=$(cut -d' ' -f1 /proc/uptime)"
} >"$L" 2>&1
chmod 666 "$L"
