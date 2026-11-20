#!/system/bin/sh
# w191_check.sh —— 只做一次计数(不循环、不扫 /proc)，把"写完触发口之后 fd 在不在"问成一句话。
L=/data/local/tmp/w191_check.out
exec >>"$L" 2>&1
PID=$(head -1 /data/local/tmp/w191_pid.txt 2>/dev/null | tr -d ' \r\n')
echo "=== check up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1) pid=[$PID] ==="
ls -1 /proc/$PID/fd 2>/dev/null | wc -l | sed 's/^/  fd 总数=/'
ls -l /proc/$PID/fd 2>/dev/null | grep -a ksu_driver | sed 's/^/  原文: /'
echo "  含 ksu_driver 的行数=$(ls -l /proc/$PID/fd 2>/dev/null | grep -c ksu_driver)"
grep -ac 'KSUFDINST 回调跑在' /data/local/tmp/dmesg.live 2>/dev/null | sed 's/^/  回调行计数=/'
grep -a 'KSUFDINST' /data/local/tmp/dmesg.live 2>/dev/null | tail -3 | sed 's/^/  /'
echo "===== DONE ====="
