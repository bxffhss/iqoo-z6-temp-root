#!/system/bin/sh
# w162_fork.sh —— 查"su 出来的 root shell 为什么 `can't fork`"(§6.164 的第一手)。
#   现场：Termux 里 /system/bin/su ⇒ SHIM-ESC `ioctl(GRANT_ROOT fd=3) ret=0 uid后=0`，提示符变成 #，
#   但紧接着 `id` 报 `/system/bin/sh: can't fork - try again`。
#   两个候选必须分开：① **cgroup 的 pids 上限**(su 的 shell 还留在 app 的 cgroup 里，我们这轮 args 是
#      `ksu_no_escape=1`，故意不逃逸)；② RLIMIT_NPROC/CPU 之类的老限制。
#   ⇒ 所以要看：那个 root sh 的 /proc/<pid>/cgroup、它所在 cgroup 的 pids.max 与 pids.current、
#      以及 /proc/<pid>/limits 里 Max processes。
L=/data/local/tmp/w162_fork.out
{
    echo "=== FORK up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    TP=$(pidof com.termux 2>/dev/null | cut -d' ' -f1)
    echo "Termux pid=[$TP]"
    echo "root sh(ppid=Termux)："
    ps -A -o PID,PPID,RUID,NAME 2>/dev/null | awk -v P="$TP" '$3 == 0 && $2 == P {print "  " $0}'
    for p in $(ps -A -o PID,PPID,RUID,NAME 2>/dev/null | awk -v P="$TP" '$3 == 0 && $2 == P {print $1}'); do
        echo "--- pid=$p ---"
        echo "  cgroup: $(cat /proc/$p/cgroup 2>&1 | tr '\n' ' ' | cut -c1-160)"
        echo "  limits: $(grep -aiE 'Max processes|Max open files' /proc/$p/limits 2>&1 | tr '\n' '|' | cut -c1-120)"
        echo "  ctx=$(cat /proc/$p/attr/current 2>/dev/null) 状态=$(awk '/^State/{print $2}' /proc/$p/status 2>/dev/null)"
        echo "  线程数=$(ls /proc/$p/task 2>/dev/null | wc -l)"
    done
    echo "pids 控制器能看到的组(挑带 termux/untrusted 的)："
    for d in /dev/cpuctl/apps /dev/cpuctl/apps/bg_non_interactive; do :; done
    for f in $(find /dev/cpuctl /acct /sys/fs/cgroup -maxdepth 4 -name 'pids.max' 2>/dev/null | head -6); do
        echo "  $f = $(cat $f 2>&1)"
    done
    echo "  cgroup 挂载点：$(grep -a cgroup /proc/self/mountinfo 2>/dev/null | awk '{print $4" "$5}' | tr '\n' ' ')"
    echo "  Termux 自己的 cgroup: $(cat /proc/$TP/cgroup 2>&1 | tr '\n' ' ' | cut -c1-160)"
    echo "  对照：agent(sushd/shd) 的 root 进程 cgroup："
    for p in $(pidof shd 2>/dev/null); do
        echo "    pid=$p $(cat /proc/$p/cgroup 2>&1 | tr '\n' ' ' | cut -c1-140) limits=$(grep -ai 'Max processes' /proc/$p/limits 2>/dev/null | tr -s ' ' | cut -c1-60)"
    done
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
