#!/system/bin/sh
# w216_verify.sh — 踢 zygote 后的注入结果验证（只读）
OUT=/data/local/tmp/w216_verify.out
exec >"$OUT" 2>&1
ZN=/data/adb/modules/zygisksu/bin/zygiskd

echo "########## [1] window + zygote restart proof ##########"
echo "ts=$(date +%Y-%m-%dT%H:%M:%S)"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
echo "up=$(cut -d' ' -f1 /proc/uptime) boot_completed=$(getprop sys.boot_completed)"
echo "enf=$(cat /sys/fs/selinux/enforce) mod=$(grep -c kernelsu /proc/modules)"
echo "zygote64=$(pidof zygote64) start_ticks=$(awk '{print $22}' /proc/$(pidof zygote64)/stat 2>/dev/null)"
echo "zygote=$(pidof zygote) system_server=$(pidof system_server)"
echo "lspd=[$(pidof lspd)] zndaemon=[$(pidof zn-daemon)] suw=[$(pidof com.suw.manager)]"

echo "########## [2] ★znctl status (the decisive readout) ##########"
timeout 10 "$ZN" status 2>&1; echo "STATUS_RC=$?"

echo "########## [3] logcat: injection evidence ##########"
logcat -d -t 1200 2>/dev/null | grep -aiE 'zn-daemon|ZygiskNext|forkAndSpecialize|module loaded|inject|LSPosed|lspd' | tail -100

echo "########## [4] processes with zygisk / lsposed in maps (root-readable) ##########"
echo "--- zygote maps: libzygisk.so ---"
grep -aE 'libzygisk|libframework|lsposed|zn_' /proc/$(pidof zygote64)/maps 2>/dev/null | head -20
echo "--- system_server maps: libframework / lsposed ---"
grep -aE 'libzygisk|libframework|lsposed|zn_' /proc/$(pidof system_server)/maps 2>/dev/null | head -20
echo "--- unix sockets (zn / lspd) ---"
grep -aE 'zn_|lspd|lspbridge' /proc/net/unix 2>/dev/null | head -25

echo "########## [5] LSPosed service registration ##########"
timeout 10 service list 2>/dev/null | grep -aiE 'serial|lspd|lsposed|activity' | head -20
echo "--- /data/adb/zygisksu state ---"
ls -la /data/adb/zygisksu/
echo "--- znctx / modules_info ---"
cat /data/adb/zygisksu/znctx 2>&1; echo
cat /data/adb/zygisksu/modules_info 2>&1; echo

echo "########## [6] LSPosed manager activation (logcat + db) ##########"
echo "--- modules log latest ---"
ML=$(ls -t /data/adb/lspd/log/modules_*.log 2>/dev/null | head -1)
echo "MODULES_LOG=$ML"; [ -n "$ML" ] && cat "$ML" 2>&1 | tail -40
echo "--- verbose log tail (activation lines) ---"
VL=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | head -1)
echo "VERBOSE=$VL"; [ -n "$VL" ] && grep -aiE 'activat|inject|loaded|module|framework|zygisk' "$VL" 2>/dev/null | tail -30

echo "########## [7] root-leg status (did @sushd survive?) ##########"
echo "--- /dev/ksud ---"; ls -la /dev/ksud 2>&1
echo "--- /product/bin/su ---"; ls -la /product/bin/su 2>&1
echo "--- managers ---"
ps -A -o PID,PPID,UID,NAME | grep -aiE 'kernelsu|suw|shd|ksuctl|adbd'
echo "===== DONE"
