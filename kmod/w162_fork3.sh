#!/system/bin/sh
# w162_fork3.sh —— 把 `can't fork` 的两个剩余候选分开读(全只读，不动任何进程)：
#   ① memcg 到顶(fork 时 charge 失败 ⇒ EAGAIN/ENOMEM)：看 /dev/memcg/apps/com.termux 的 limit/usage/failcnt
#   ② v2 组里的限制文件(pids/threads 类)：列 /sys/fs/cgroup/uid_10667/pid_30188 下所有可读的 *max*/*current*
#   ③ 顺手看那个 root shell 的父进程链(31076 的 PPid 是 24242，不是 app 主进程 ⇒ 到底谁在管着它)
L=/data/local/tmp/w162_fork3.out
{
    echo "=== FORK3 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    echo "① memcg:"
    for d in /dev/memcg/apps/com.termux /dev/memcg/apps /dev/memcg; do
        [ -d "$d" ] || continue
        echo "  $d limit=$(cat $d/memory.limit_in_bytes 2>&1) usage=$(cat $d/memory.usage_in_bytes 2>&1) max_usage=$(cat $d/memory.max_usage_in_bytes 2>&1) failcnt=$(cat $d/memory.failcnt 2>&1)"
    done
    echo "  soft_limit=$(cat /dev/memcg/apps/com.termux/memory.soft_limit_in_bytes 2>&1) kmem_failcnt=$(cat /dev/memcg/apps/com.termux/memory.kmem.failcnt 2>&1)"
    echo "② v2 组 $(ls -d /sys/fs/cgroup/uid_10667/pid_30188 2>&1):"
    for f in /sys/fs/cgroup/uid_10667/pid_30188/*max* /sys/fs/cgroup/uid_10667/pid_30188/*current* /sys/fs/cgroup/uid_10667/pid_30188/pids.*; do
        [ -e "$f" ] || continue
        echo "  $(basename $f)=$(cat $f 2>&1 | tr '\n' ' ')"
    done
    echo "  根组: $(for f in /sys/fs/cgroup/pids.max /sys/fs/cgroup/pids.current; do [ -e $f ] && echo -n "$(basename $f)=$(cat $f 2>&1) "; done)"
    echo "③ 父进程链(从 31076 往上)："
    p=31076
    for i in 1 2 3 4 5; do
        [ -d /proc/$p ] || { echo "  pid=$p 已不在"; break; }
        echo "  pid=$p ppid=$(awk '/^PPid/{print $2}' /proc/$p/status) uid=$(awk '/^Uid/{print $2}' /proc/$p/status) cmd=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-60)"
        p=$(awk '/^PPid/{print $2}' /proc/$p/status)
        [ "$p" = "1" ] && { echo "  pid=1 init"; break; }
    done
    echo "④ 那个 root shell 能不能被自己看见线程/文件描述符数量异常：Threads=$(awk '/^Threads/{print $2}' /proc/31076/status 2>/dev/null) fd=$(ls /proc/31076/fd 2>/dev/null | wc -l)"
    echo "  它的 RLIMIT: $(cat /proc/31076/limits 2>/dev/null | grep -aiE 'processes|files' | tr -s ' \n' ' ')"
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
