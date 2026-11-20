#!/system/bin/sh
# w340_ksudwatch.sh —— **纯只读**：把"官方 Manager exec libksud.so 那一下"的现场捞干净，给 #125(自再执行改道) 定生死。
#   为什么不需要采样也不需要改 ko：libksud 进程只活约 1ms(第一个 syscall=reboot(142) 就被 seccomp 打死)，
#   但**两个地方会留下完整记录**：①ksud 自己往 logcat 打 `ksud::cli: command: <解析后的 argv>`；
#   ②aborter 写的 tombstone 头里有 `Cmdline: <完整路径> <argv…>`。
#   要回答的三个问题：filename 到底是什么、argv 有多少、env 需不需要原样重放。
# ★规矩：块级重定向，块内绝不 cat 自己的输出(§6 那条自喂账：设备侧 12.4 GB / 主机 11.9 GB)。
O=/data/local/tmp/w340_ksudwatch.out
{
    echo "=== W340 只读 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c kernelsu /proc/modules) ==="
    echo "--- 1) crash 缓冲：SIGSYS 与 tombstone 里的 Cmdline/>>> ---"
    logcat -d -b crash -v time 2>/dev/null | grep -aE "SIGSYS|signal 31|Cmdline|>>>" | tail -14
    echo "--- 2) 最近的 tombstone 头 14 行(这才有完整 filename+argv) ---"
    for t in $(ls -t /data/tombstones 2>/dev/null | grep -av '\.pb$' | head -2); do
        echo "### /data/tombstones/$t"
        head -14 "/data/tombstones/$t" 2>&1
    done
    echo "--- 3) 主 logcat 里 ksud 自己打的 argv 解析 + Manager 侧的反应 ---"
    logcat -d -v time 2>/dev/null | grep -aE "ksud::cli|KsuCli|libksud" | tail -22
    echo "--- 4) 对照：Manager 进程的 seccomp/cred 现状(app 域) ---"
    M=$(pidof me.weishu.kernelsu 2>/dev/null); M=$(echo $M | cut -d' ' -f1)
    if [ -n "$M" ]; then
        echo "  Manager pid=$M"; grep -aE '^(Uid|Gid|CapEff|NoNewPrivs|Seccomp|MDSECCOMP)' /proc/$M/status 2>&1
        grep -a '^/' /proc/$M/maps 2>/dev/null | grep -am1 "lib/arm64" | cut -c1-140
    else
        echo "  Manager 没在跑(先 am start 再跑这条腿)"
    fi
    echo "--- 5) 内核侧：我们的钩子/stage 有没有见过这个 execve ---"
    grep -a "libksud\|allow root for\|KSUFDINST" /data/local/tmp/ksu_stage.log 2>/dev/null | tail -8
    echo "--- 6) APK 的 native lib 目录(shell 读不到，root 读)：libksud 的真实路径与权限 ---"
    for d in /data/app/*/*/lib/arm64; do
        ls -lZ "$d" 2>/dev/null | grep -a "libksud\|libadbroot" | sed "s|^|  $d -> |"
    done
    echo "=== DONE ==="
} > "$O" 2>&1
chmod 666 "$O" 2>/dev/null
