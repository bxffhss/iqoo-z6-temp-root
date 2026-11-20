#!/system/bin/sh
# w213_lspd2.sh — 修 w212 的 pkill -f 自杀 bug；用 system_server 域重试 lspd 并多次采样
OUT=/data/local/tmp/w213_lspd2.out
exec >"$OUT" 2>&1
M=/data/adb/modules
LP=$M/zygisk_lsposed
BB=/data/adb/ksu/bin/busybox

echo "########## [1] precise kill old lspd (avoid pkill -f self-kill) ##########"
for p in $(pidof lspd 2>/dev/null); do echo "kill lspd pid=$p"; kill -9 "$p" 2>/dev/null; done
sleep 1
echo "lspd_after=$(pidof lspd)"

echo "########## [2] skip_online_request (安装期检查；license.pb 缺时的合规旁路) ##########"
mkdir -p /data/adb/lspd
: > /data/adb/lspd/skip_online_request
chmod 0666 /data/adb/lspd/skip_online_request
ls -la /data/adb/lspd/skip_online_request

echo "########## [3] retry with system_server domain (Z5 recipe) ##########"
rm -f /data/local/tmp/daemon.apk /data/local/tmp/manager.apk
cd "$LP" || exit 1
echo "self_ctx=$(cat /proc/self/attr/current)"
nohup "$BB" setsid runcon u:r:system_server:s0 sh -c "cd $LP && exec ./daemon --force" >/data/local/tmp/w213_lspd.log 2>&1 </dev/null &
echo "SPAWN_PID=$!"

for t in 1 2 3 4; do
  sleep 4
  echo "--- sample t+$((t*4))s ---"
  echo "lspd_pid=[$(pidof lspd)]"
  ps -A -o PID,PPID,UID,NAME | grep -aiE 'lspd|app_process'
done

echo "########## [4] daemon wrapper log ##########"
cat /data/local/tmp/w213_lspd.log

echo "########## [5] fresh LSPosed logcat ##########"
logcat -d -t 250 2>/dev/null | grep -aiE 'LSPosed|lspd|LSPosedService|LSPosedBridge|dex2oat' | tail -50

echo "########## [6] latest verbose log tail ##########"
VL=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | head -1)
echo "VERBOSE=$VL"
[ -n "$VL" ] && tail -40 "$VL" 2>&1

echo "########## [7] zn status (injector still healthy?) ##########"
timeout 8 "$M/zygisksu/bin/zygiskd" status 2>&1 | grep -aE 'version:|zygote_states|inject_state|root_status|modules'; echo "RC=$?"

echo "########## [8] window state ##########"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) up=$(cut -d' ' -f1 /proc/uptime)"
echo "enf=$(cat /sys/fs/selinux/enforce) mod=$(grep -c kernelsu /proc/modules) boot_completed=$(getprop sys.boot_completed)"
echo "zygote64=$(pidof zygote64) suw=$(pidof com.suw.manager) zndaemon=$(pidof zn-daemon)"
echo "===== DONE"
