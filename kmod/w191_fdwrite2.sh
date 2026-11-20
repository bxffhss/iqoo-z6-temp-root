#!/system/bin/sh
# w191_fdwrite2.sh —— 把"写触发口"单独隔离：**不扫 /proc**，pid 由文件传进来(读腿已经确认过那个 pid)。
#   为什么这么切：上一发的写腿只有表头、没有 DONE，它死在"扫 /proc/*/cmdline 找 pid"那一段，
#   根本没走到 `echo <pid> > /proc/ksu_install_fd` ⇒ 那条 ★ 结论不能算在写路径上(§6.193)。
L=/data/local/tmp/w191_fdwrite2.out
exec >>"$L" 2>&1
PID=$(head -1 /data/local/tmp/w191_pid.txt 2>/dev/null | tr -d ' \r\n')
echo "=== fdwrite2 up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1) id=$(id) pid=[$PID] ==="
[ -e "/proc/$PID" ] || { echo "[x] 那个 pid 不在了"; echo "===== DONE ====="; exit 0; }
[ -e /proc/ksu_install_fd ] || { echo "[x] 触发口不在"; echo "===== DONE ====="; exit 0; }
echo "A1 扫之前: fd 数=$(ls -1 /proc/$PID/fd 2>/dev/null | wc -l) 含 ksu_driver=$(ls -l /proc/$PID/fd 2>/dev/null | grep -ac ksu_driver)"
echo "$PID" > /proc/ksu_install_fd
echo "A2 写下去 rc=$?"
for r in 1 2 3 4 5 6; do
    sleep 5
    K=$(ls -l /proc/$PID/fd 2>/dev/null | grep -ac ksu_driver)
    N=$(ls -1 /proc/$PID/fd 2>/dev/null | wc -l)
    echo "A3 t+$((r*5))s fd 数=$N 含 ksu_driver=$K"
    [ "$K" != "0" ] && break
done
ls -l /proc/$PID/fd 2>/dev/null | grep -a ksu_driver | sed 's/^/  原文: /'
grep -a "KSUFDINST" /data/local/tmp/dmesg.live 2>/dev/null | tail -4 | sed 's/^/  回调: /'
echo "A4 活着收尾 up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1)"
echo "===== DONE ====="
