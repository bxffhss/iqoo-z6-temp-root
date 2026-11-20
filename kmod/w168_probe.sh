#!/system/bin/sh
# w168_probe.sh —— #72 的第二次测量：把"escape 之后不能 fork"钉到具体哪一格。
#   三个上下文一次跑完(每一格都是同一个 forkprobe，只是"怎么变成 uid 0"不同)：
#     C0 本任务(不 escape)                 ⇒ 正对照：探针本身没问题(§6.165 已证一次，这发再拿一次)
#     C2 escape 成**目标 uid**(名单里的 profile，域=shell) ⇒ 复现 §6.165 那一发(期望 fork/vfork/pthread EPERM)
#     C1 escape 成**王座 uid**(走 default_root_profile)     ⇒ ★这发新加的一格：一手事实是
#        "@sushd: 那条 root 通道整晚都在正常 fork 跑脚本"，而 su shell 不能 ⇒ 变量从来不是"escape"本身，
#        而是"哪一个 profile / 哪一个域 / 是不是宽容"。C1 与 C2 就是这一格的对照。
#   顺序有讲究：C1 有可能把整窗打成 Permissive(§记忆里"整窗 Permissive 是我们自己的枪"那一发)，
#   而宽容状态下 avc 判定根本不会报错 ⇒ 所以**先跑要判定的 C2**，并且**每一格前后都印 getenforce**。
#   ★日志一律 >> 追加：fork 出来的孩子与父进程共享文件 offset，用 > 会互相盖掉字节
#     (本机 smoke test 现场演示过一次：LC 三行被另一个写者盖掉，看着像"没跑")。
L=/data/local/tmp/w168_probe.out
PR=/data/local/tmp/forkprobe
CTL=/data/local/tmp/ksuctl88
{
    : >"$L"
    chmod 666 "$L" 2>/dev/null   # 立刻放开：中途任何一格退出，PC 侧(uid 2000)也读得到存证
    exec >>"$L" 2>&1
    echo "=== P8 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) uts=$(uname -s)"
    echo "  md5 PR=$(md5sum $PR 2>&1 | cut -c1-32) CTL=$(md5sum $CTL 2>&1 | cut -c1-32)"
    U1=$(cat /data/local/tmp/w168_u1.uid 2>/dev/null | tr -dc '0-9')
    U2=$(cat /data/local/tmp/w168_u2.uid 2>/dev/null | tr -dc '0-9')
    for v in U1 U2; do
        eval "X=\$$v"
        case "$X" in
            [0-9][0-9][0-9] | [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
            *) echo "[x] $v=[$X] 不是 uid ⇒ 不跑(写错 uid 整发判据打空)"; echo "===== DONE"; exit 0 ;;
        esac
    done
    chmod 755 "$PR" 2>/dev/null
    DM0=$(dmesg 2>/dev/null | wc -l)
    echo "  dmesg 行数(跑之前)=$DM0"

    echo "--- C0 正对照：本任务直接跑探针(enf=$(getenforce)) ---"
    "$PR" C0
    echo "--- C0 完 enf=$(getenforce) ---"

    echo "--- C2 escape 成目标 uid=$U1(名单 profile，域=shell)：这是要判定的一格(enf=$(getenforce)) ---"
    "$CTL" grant "$U1" "$PR" C2
    echo "--- C2 完 enf=$(getenforce) ---"

    echo "--- C1 escape 成王座 uid=$U2(default_root_profile)：对照(enf=$(getenforce)) ---"
    "$CTL" grant "$U2" "$PR" C1
    echo "--- C1 完 enf=$(getenforce) ---"

    echo "--- 内核这一发说了什么(dmesg 尾巴 + 关键字) ---"
    dmesg 2>/dev/null | tail -70
    echo "--- 关键字过滤(没有也正常，只是观测器可能哑) ---"
    dmesg 2>/dev/null | grep -aiE "avc:|KSUBEAT|unrecognized SID|Process fork|clone|denied|WARNING|Oops|BUG:|vivo|selinux" | tail -40
    DM1=$(dmesg 2>/dev/null | wc -l)
    echo "  dmesg 行数(跑之后)=$DM1 (差=$((DM1 - DM0)))"
    echo "--- 顺带：厂商在不在 syscall 路径上下了 kprobe(kprobes/list = 谁装了探针的权威清单) ---"
    D=/sys/kernel/debug
    [ -d "$D/tracing" ] || mount -t debugfs nodev "$D" 2>&1
    echo "  kprobes 总数=$(grep -ac . $D/kprobes/list 2>/dev/null)"
    grep -aiE "clone|fork|setuid|setresuid|execve|copy_process|cred|seccomp" $D/kprobes/list 2>/dev/null | head -20
    echo "  -- 全表前 30 行 --"
    head -30 $D/kprobes/list 2>&1
    echo "  enabled_probes: $(cat $D/tracing/enabled_probes 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
    echo "--- 厂商在 fork 路径上有没有自己的执法者(kallsyms 里跟 clone/fork/setid 相关的名字) ---"
    grep -aiE " (copy_process|_do_fork|kernel_clone|__arm64_sys_clone3?|safesetid.*)$" /proc/kallsyms 2>/dev/null | head -10
    grep -aciE "vivo|vendor|iqoo" /proc/kallsyms 2>/dev/null | sed 's/^/  含 vivo|vendor|iqoo 的符号数=/'
    echo "===== DONE"
} 2>&1
chmod 666 "$L" 2>/dev/null
