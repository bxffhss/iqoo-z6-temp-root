#!/system/bin/sh
# w161_fdlaunch.sh —— 用 suw 的 root 通道把看门狗**脱离通道**跑起来(setsid)。
#   为什么单独一份：@sushd: 派发的子进程会随会话结束被带走，而看门狗要活几分钟；
#   并且它必须活过"PC 侧起 Manager"那一段(§6.62：跨踢观测/清理一律 setsid)。
# ★杀旧实例只认 pid 文件，不用 pgrep -f(那条会连命令行一起匹配 ⇒ 有朝自己开枪的风险)。
L=/data/local/tmp/w161_fdlaunch.out
PIDF=/data/local/tmp/w161_fdwatch.pid
{
    echo "=== FDL up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) ==="
    if [ -e /proc/ksu_install_fd ]; then
        echo "  触发口在: $(ls -l /proc/ksu_install_fd 2>&1 | tail -1)"
    else
        echo "  !! 触发口不在 ⇒ 这一发后面所有'fd 没装上'的读数都不能算结论"
    fi
    if [ -f "$PIDF" ]; then
        OLD=$(tr -dc '0-9' < "$PIDF")
        case "$OLD" in ''|*[!0-9]*) OLD="" ;; esac
        [ -n "$OLD" ] && { kill -9 "$OLD" 2>/dev/null; echo "  杀掉旧看门狗 pid=$OLD(rc=$?)"; }
    fi
    rm -f "$PIDF" /data/local/tmp/w161_fdwatch.log
    ( setsid nohup /system/bin/sh /data/local/tmp/w161_fdwatch.sh >/dev/null 2>&1 </dev/null & )
    sleep 2
    NP=$(tr -dc '0-9' < "$PIDF" 2>/dev/null)
    if [ -n "$NP" ] && [ -d "/proc/$NP" ]; then
        echo "  看门狗活着 pid=$NP uid=$(awk '/^Uid/{print $2}' /proc/$NP/status)"
    else
        echo "  !! 看门狗没起来(pid 文件=[$(cat "$PIDF" 2>/dev/null)])"
    fi
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
