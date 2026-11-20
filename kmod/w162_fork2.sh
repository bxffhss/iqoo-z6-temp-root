#!/system/bin/sh
# w162_fork2.sh —— 上一版找错了对象：Termux 的 su shell 的父进程是**它自己那个 bash**，不是 app 主进程。
#   ⇒ 这次直接列"所有 ruid=0 且名字像 shell 的进程"，把 newest 那一个的
#      cgroup / limits / Seccomp / Threads / pid_max / threads-max 全读一遍，
#      目标是分清 `can't fork`(EAGAIN) 到底来自 RLIMIT_NPROC、pid_max、还是 seccomp 对 clone 的拦截。
L=/data/local/tmp/w162_fork2.out
{
    echo "=== FORK2 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    echo "系统上限：kernel.pid_max=$(cat /proc/sys/kernel/pid_max 2>&1) threads-max=$(cat /proc/sys/kernel/threads-max 2>&1)"
    echo "现在的任务总数=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)"
    echo "候选 root shell："
    ps -A -o PID,PPID,RUID,ETIME,NAME 2>/dev/null | awk '$3 == 0 && ($4 ~ /sh$|bash$/)' | sed 's/^/  /'
    for p in $(ps -A -o PID,RUID,NAME 2>/dev/null | awk '$2 == 0 && ($3 ~ /^sh$|^bash$/) {print $1}'); do
        echo "--- pid=$p ---"
        echo "  cmd=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-70)"
        echo "  etime=$(awk '/^Threads/{print "Threads="$2}' /proc/$p/status 2>/dev/null) $(grep -aE '^(PPid|State|Uid|Seccomp|Seccomp_filters|Cpus_allowed_list)' /proc/$p/status 2>/dev/null | tr '\n' ' ')"
        echo "  limits=$(grep -aiE 'Max processes|Max open files' /proc/$p/limits 2>/dev/null | tr -s ' \n' ' ')"
        echo "  cgroup=$(cat /proc/$p/cgroup 2>/dev/null | tr '\n' ' ')"
        echo "  ctx=$(cat /proc/$p/attr/current 2>/dev/null)"
    done
    echo "有没有 pids 控制器：$(grep -ac ' pids ' /proc/self/mountinfo 2>/dev/null) 行；cgroup 里带 pids.max 的文件数=$(find /sys/fs/cgroup /dev/cpuctl /acct -maxdepth 5 -name pids.max 2>/dev/null | wc -l)"
    echo "seccomp 对 clone 的态度(只读 /proc/self/seccomp* 之类，不做任何系统调用实验)：$(ls /proc/self/ 2>/dev/null | grep -a seccomp | tr '\n' ' ')"
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
