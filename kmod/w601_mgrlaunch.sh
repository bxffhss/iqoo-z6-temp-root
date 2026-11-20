#!/system/bin/sh
# w601_mgrlaunch.sh —— 把 w600_mgrwatch.sh 以 setsid **脱离 root 通道**跑起来(常驻)，并先把旧仪器清场。
#   为什么先杀 w161_fdwatch：那条是"400×0.4s≈160 秒"的抢装窗口，它要是还在跑，
#   后面"关掉常驻看门狗⇒牌子必须退回"那格反对照就分不清是谁装的 fd(例 167：先查被测对象此刻有没有别的生产者)。
L=/data/local/tmp/w601_mgrlaunch.out
{
    echo "=== L601 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) ==="
    if ls -l /proc/ksu_install_fd >/dev/null 2>&1; then
        echo "  触发口在: $(ls -l /proc/ksu_install_fd | tail -1)"
    else
        echo "  !! 触发口不在 ⇒ 这一发所有'fd 没装上'的读数都不算结论"
    fi
    for PF in /data/local/tmp/w161_fdwatch.pid /data/local/tmp/w600_mgrwatch.pid; do
        if [ -f "$PF" ]; then
            OLD=$(tr -dc '0-9' < "$PF")
            case "$OLD" in '' | *[!0-9]*) OLD="" ;; esac
            if [ -n "$OLD" ] && [ -d "/proc/$OLD" ]; then
                kill -9 "$OLD" 2>/dev/null; echo "  清场: 杀掉 $PF 记的 pid=$OLD(rc=$?)"
            else echo "  清场: $PF 里没有活进程"; fi
        else echo "  清场: $PF 不存在"; fi
    done
    rm -f /data/local/tmp/w600_mgrwatch.log /data/local/tmp/w600_mgrwatch.pid
    : > /data/local/tmp/ksu_mgr_watch
    chmod 666 /data/local/tmp/ksu_mgr_watch
    ( setsid nohup /system/bin/sh /data/local/tmp/w600_mgrwatch.sh >/dev/null 2>&1 </dev/null & )
    sleep 3
    NP=$(tr -dc '0-9' < /data/local/tmp/w600_mgrwatch.pid 2>/dev/null)
    if [ -n "$NP" ] && [ -d "/proc/$NP" ]; then
        echo "  常驻看门狗活着 pid=$NP uid=$(awk '/^Uid/{print $2}' /proc/$NP/status) ppid=$(awk '/^PPid/{print $2}' /proc/$NP/status)"
        echo "  它 3 秒内的日志: $(tr '\n' '|' < /data/local/tmp/w600_mgrwatch.log 2>/dev/null | cut -c1-200)"
        echo "  MGR-ALIVE pid=$NP"
    else
        echo "  !! 看门狗没起来(pid 文件=[$(cat /data/local/tmp/w600_mgrwatch.pid 2>/dev/null)]) ⇒ MGR-DEAD"
    fi
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
