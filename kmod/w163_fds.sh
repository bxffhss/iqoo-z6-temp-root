#!/system/bin/sh
# w163_fds.sh —— 备择假设的探针(§6.153 末尾那条收窄)：libsu 交给 root shell 的那个 **socket fd**
#   到底有没有活过 `su → 静态 su → execve /system/bin/sh` 这条链。
#   如果 shell 的 fd 表里连一个 unix socket 都没有，那"RootService 起不来"就跟 SELinux 域无关，
#   而是 **fd 在 exec 时被关掉/没带过去(CLOEXEC 或 dup 丢了)**。
# ★只读侦察：不改别人的进程、不发消息、不写名单。
L=/data/local/tmp/w163_fds.out
{
    echo "=== FDS up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) ==="
    MP=$(pidof me.weishu.kernelsu 2>/dev/null | cut -d' ' -f1)
    echo "Manager pid=[$MP]"
    [ -n "$MP" ] || { echo "  (Manager 没在跑 ⇒ 这一格按没测到算)"; echo "===== DONE"; exit 0; }
    for p in $(pgrep -P "$MP" 2>/dev/null); do
        echo "--- 子进程 pid=$p ---"
        echo "  cmd=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-90)"
        echo "  uid=$(awk '/^Uid/{print $2}' /proc/$p/status 2>/dev/null) ctx=$(cat /proc/$p/attr/current 2>/dev/null) 父=$(awk '/^PPid/{print $2}' /proc/$p/status 2>/dev/null)"
        echo "  fd 表(全量)："
        ls -l /proc/$p/fd 2>/dev/null | tail -n +2 | sed 's/^/    /' | head -16
        echo "  其中 unix socket 条数=$(ls -l /proc/$p/fd 2>/dev/null | grep -ac 'socket:\[')"
        echo "  其中 ksu 条数=$(ls -l /proc/$p/fd 2>/dev/null | grep -ac ksu)"
    done
    echo "--- 全机器 root 的 app_process / 官方 Manager 名下的孙进程 ---"
    ps -A -o PID,PPID,RUID,NAME 2>/dev/null | awk '$3 == 0 && $4 !~ /^\[/ {print "  " $0}' | grep -aiE 'app_process|weishu' | head -6
    echo "  (空=没有)"
    for p in $(pgrep -P "$MP" 2>/dev/null); do
        for g in $(pgrep -P "$p" 2>/dev/null); do
            echo "  孙 pid=$g cmd=$(tr '\0' ' ' < /proc/$g/cmdline 2>/dev/null | cut -c1-120)"
        done
    done
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
