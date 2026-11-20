#!/system/bin/sh
L=/data/local/tmp/w196_fire.out
exec >>"$L" 2>&1
echo "=== fire up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1) id=$(id) ==="
rm -f /data/local/tmp/w161_fdwatch.log
setsid nohup /data/local/tmp/w161_fdwatch.sh >/dev/null 2>&1 </dev/null &
echo "看门狗 pid=$(cat /data/local/tmp/w161_fdwatch.pid 2>/dev/null)"
runcon u:r:shell:s0 am force-stop me.weishu.kernelsu 2>/dev/null
runcon u:r:shell:s0 am start -n me.weishu.kernelsu/.ui.MainActivity >/dev/null 2>&1
echo "起完 pidof=[$(pidof me.weishu.kernelsu | cut -d' ' -f1)] up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1)"
echo "===== DONE ====="
