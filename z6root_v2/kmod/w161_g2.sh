#!/system/bin/sh
# w161_g2.sh —— 内核/进程侧的权威复读(完全不依赖官方界面能不能被自动化读到)。
#   四件事一次问清：
#     A) fd 到底装进 Manager 了没有：/proc/<pid>/fd 里那条 ksu 匿名 fd + 内核的回调行
#        (★"已排队"不算 —— 上一发就是被这句骗过去的)
#     B) 王座与名单：GET_MANAGER_APPID / 两个 uid 的 UID_GRANTED_ROOT
#     C) ★#61 的正判据：点进超级用户页之后，**比上一次多出哪些 ruid=0 的用户态进程**。
#        官方 Manager 的 libsu RootService 要先由 app 侧 shell 出 su ⇒ 起来了就一定多一个 root 进程。
#        用"与上一次快照的差集"而不是"绝对数量"：本机开机就有几百个 root 的内核线程/守护，
#        绝对数没有任何分辨力(实测 ruid=0 共 575 行)。
#     D) 内核看到的 su 执行事件(KSUBEAT)
L=/data/local/tmp/w161_g2.out
R0=/data/local/tmp/w161_r0.txt
{
    echo "=== G2 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) ==="
    MP=$(pidof me.weishu.kernelsu 2>/dev/null | cut -d' ' -f1)
    echo "A) Manager pid=[$MP]"
    if [ -n "$MP" ]; then
        echo "   fd 表里带 ksu 的条数=$(ls -l /proc/$MP/fd 2>/dev/null | grep -ac ksu)"
        ls -l /proc/$MP/fd 2>/dev/null | grep -a ksu | head -3 | sed 's/^/   /'
    fi
    grep -a KSUFDINST /data/local/tmp/dmesg.live 2>/dev/null | tail -6 | cut -c1-150 | sed 's/^/   /'
    echo "   ★只算 comm 带 weishu 的回调行数=$( grep -a 'KSUFDINST 回调跑在' /data/local/tmp/dmesg.live 2>/dev/null | grep -ac weishu )(dmesg.live 会跨重启残留，别把上一发的行当本发)"
    echo "   看门狗日志尾巴:"
    tail -4 /data/local/tmp/w161_fdwatch.log 2>/dev/null | sed 's/^/   /'
    for c in /data/local/tmp/ksuctl87 /data/local/tmp/ksuctl; do
        if [ -x "$c" ]; then
            echo "B) 用 $c:"
            "$c" mgr 2>&1 | grep -a GET_MANAGER_APPID | cut -c1-140 | sed 's/^/   /'
            for f in /data/local/tmp/w161_u1.uid /data/local/tmp/w161_u2.uid; do
                T=$(cat "$f" 2>/dev/null | tr -dc '0-9')
                case "$T" in
                  [0-9][0-9][0-9] | [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
                  *) T="" ;;
                esac
                if [ -n "$T" ]; then
                    echo "   uid=$T : $( "$c" granted "$T" 2>&1 | grep -a UID_GRANTED_ROOT | cut -c1-120 )"
                else
                    echo "   $f: bad-uid ⇒ 这一格按没测到算"
                fi
            done
            break
        fi
        echo "B) (没有可执行的 $c)"
    done
    # ★把我自己这条链(被 sushd 派发的 sh、它的父进程…)从"新增 root 进程"里剔掉，
    #   否则每次复读都会把自己算成一条阳性(记忆例 27 那一族：判据标签自命中)。
    EX=""; Q=$$
    for k in 1 2 3 4 5 6 7 8; do
        [ -n "$EX" ] && case "$EX" in *" $Q "*) break ;; esac
        EX="$EX $Q "
        PP=$(cut -d')' -f2- /proc/$Q/stat 2>/dev/null | awk '{print $2}')
        case "$PP" in ''|*[!0-9]*) break ;; esac
        [ "$PP" = "0" ] && break
        Q=$PP
    done
    echo "C) 剔掉自身链(排除 pid:$EX)后的 ruid=0 用户态进程快照："
    ps -A -o PID,PPID,RUID,NAME 2>/dev/null | awk -v X="$EX" '
        NR > 1 && $3 == 0 && $4 !~ /^\[/ {
            drop = 0
            n = split(X, a, " ")
            for (j = 1; j <= n; j++) if (a[j] == $1) drop = 1
            if (!drop) print "   " $0
        }' | head -20
    if [ -f "$R0" ]; then
        echo "   ★比上一次多出来的 ruid=0 进程(这就是 libsu 的正判据)："
        ps -A -o PID,PPID,RUID,NAME 2>/dev/null | awk '$3 == 0 && $4 !~ /^\[/ {print $1" "$4}' |
            while read -r pid name; do
                grep -aq "^$pid " "$R0" 2>/dev/null || echo "     新增 pid=$pid name=$name"
            done | head -10
    else
        echo "   (第一次跑：只建基线，差集下一轮才有)"
    fi
    ps -A -o PID,PPID,RUID,NAME 2>/dev/null | awk '$3 == 0 && $4 !~ /^\[/ {print $1" "$4}' > "$R0"
    echo "   基线已存 $R0 ($(wc -l < "$R0") 行)"
    echo "   Manager 名下的子进程(ppid=$MP)："
    if [ -n "$MP" ]; then
        ps -A -o PID,PPID,RUID,NAME 2>/dev/null | awk -v P="$MP" '$2 == P {print "     " $0}' | head -8
    fi
    logcat -d -t 400 2>/dev/null | grep -aiE 'KsuService|RootService|libsu|ShellThread' | tail -8 | cut -c1-150 | sed 's/^/   /'
    echo "D) KSUBEAT 里与 su 执行有关的行(最多 10 行)："
    grep -aE 'KSUBEAT (SU0|X7|X8)' /data/local/tmp/dmesg.live 2>/dev/null | tail -10 | cut -c1-150 | sed 's/^/   /'
    echo "=== DONE ==="
} > "$L" 2>&1
chmod 666 "$L"
