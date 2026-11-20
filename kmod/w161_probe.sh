#!/system/bin/sh
# w161_probe.sh —— libsu 那条 root shell 到底活着没、它拿什么当 stdin/stdout。
#   现场：官方 Manager 名下有两个 ruid=0 的 sh(=libsu 的 root shell 起来了)，
#   但**没有 root 侧 app_process**(=KsuService 那个 RootService 宿主从没起来) ⇒ 开关写不回内核。
#   所以要分清：是"libsu 往 shell 里写的命令没被执行"还是"被执行了但 app_process 起不来"。
L=/data/local/tmp/w161_probe.out
{
    MP=$(pidof me.weishu.kernelsu 2>/dev/null | cut -d' ' -f1)
    echo "=== PRB up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) Manager pid=[$MP] ==="
    echo "A) Manager 名下的 root 子进程："
    [ -n "$MP" ] && ps -A -o PID,PPID,RUID,STATE,NAME 2>/dev/null | awk -v P="$MP" '$2 == P {print "   " $0}'
    for p in $( [ -n "$MP" ] && pgrep -P "$MP" ); do
        echo "B) pid=$p 的 fd(看 stdin 是不是管道/pty)："
        ls -l /proc/$p/fd 2>/dev/null | head -8 | sed 's/^/   /'
        echo "   exe=$(ls -l /proc/$p/exe 2>/dev/null | sed 's/.*-> //')"
        grep -aE '^(Uid|Gid|Seccomp|Seccomp_filters|NoNewPrivs|PPid)' /proc/$p/status 2>/dev/null | sed 's/^/   /'
    done
    echo "C) 全机器上有没有 root 的 app_process / KsuService 宿主："
    ps -A -o PID,PPID,RUID,NAME 2>/dev/null | awk '$3 == 0 && $4 !~ /^\[/' | grep -aiE 'app_process|weishu' | head -5
    echo "   (空=没有)"
    echo "D) crash buffer 里与官方 Manager 相关的行："
    logcat -d -b crash -t 200 2>/dev/null | grep -aiE 'weishu|kernelsu|app_process' | tail -8 | cut -c1-170 | sed 's/^/   /'
    echo "   (空=崩溃缓冲里没有它)"
    echo "E) 内核侧最近有没有收到 SET_APP_PROFILE 类的调用痕迹："
    grep -aiE 'SET_APP_PROFILE|set_profile|apfmt|invalid app_profile|perm_check' /data/local/tmp/dmesg.live 2>/dev/null | tail -6 | cut -c1-160 | sed 's/^/   /'
    echo "   (空=一次都没收到)"
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
