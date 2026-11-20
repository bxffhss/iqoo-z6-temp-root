#!/system/bin/sh
# w161_fd1.sh —— 手动补一发"给当前 Manager pid 装驱动 fd"，并把结果落在自己的 out 文件里。
#   为什么还要它：看门狗只跑 160s，Manager 中途重启过(pid 换了) ⇒ fd 表里带 ksu 的条数掉回 0 ⇒
#   官方 App Profile 页那个"超级用户"开关点了会**弹回原样**(它要用自己的 fd 发 SET_APP_PROFILE)。
#   pid 从文件读，不用 sed 往脚本里塞(记忆例33 那一族)。
L=/data/local/tmp/w161_fd1.out
{
    P=$(cat /data/local/tmp/w161_mgr.pid 2>/dev/null | tr -dc '0-9')
    case "$P" in '' | *[!0-9]*) echo "  bad-pid=[$P] ⇒ 不写触发口"; echo "===== DONE"; exit 0 ;; esac
    echo "=== FD1 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 目标 pid=$P ==="
    if echo "$P" > /proc/ksu_install_fd; then echo "  写触发口成功"; else echo "  !! 写触发口失败"; fi
    for k in 1 2 3 4 5 6 7 8; do
        sleep 2
        N=$(ls -l /proc/$P/fd 2>/dev/null | grep -ac ksu)
        echo "  第 $k 次查：fd 表里带 ksu 的条数=$N"
        [ "${N:-0}" != "0" ] && break
    done
    ls -l /proc/$P/fd 2>/dev/null | grep -a ksu | head -3 | sed 's/^/  /'
    grep -a 'KSUFDINST 回调跑在' /data/local/tmp/dmesg.live 2>/dev/null | tail -2 | cut -c1-150 | sed 's/^/  /'
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
