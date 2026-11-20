#!/system/bin/sh
# w207_diag.sh — 诊断 zygiskd daemon 为何起不来：前台跑+抓 logcat+查 KSU 接口
OUT=/data/local/tmp/w207_diag.out
exec >"$OUT" 2>&1
M=/data/adb/modules
ZN=$M/zygisksu

echo "########## [1] baseline before retry ##########"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
echo "enf=$(cat /sys/fs/selinux/enforce) mod=$(grep -c kernelsu /proc/modules)"
echo "zygote64=$(pidof zygote64) suw=$(pidof com.suw.manager)"
echo "--- .injecting / magic ---"
ls -la /data/adb/zygisksu/
echo "--- existing zn processes ---"
ps -A -o PID,PPID,UID,NAME | grep -aiE 'zygisk|zn-daemon|lspd|machikado'

echo "########## [2] clear stale .injecting ##########"
rm -f /data/adb/zygisksu/.injecting

echo "########## [3] foreground daemon run (cd into module dir, timeout 12) ##########"
cd "$ZN" || { echo "CD_FAIL"; }
timeout 12 ./bin/zygiskd daemon 2>&1; echo "DAEMON_RC=$?"
echo "--- processes right after ---"
ps -A -o PID,PPID,UID,NAME | grep -aiE 'zygisk|zn-daemon|lspd|machikado'
echo "--- /data/adb/zygisksu after ---"
ls -la /data/adb/zygisksu/

echo "########## [4] status ##########"
timeout 8 ./bin/zygiskd status 2>&1; echo "STATUS_RC=$?"

echo "########## [5] logcat: zygisk/zn/lspd/KSU (last 200 relevant) ##########"
logcat -d -t 300 2>/dev/null | grep -aiE 'zygisk|zn-daemon|zn_|ZygiskNext|lspd|LSPosed|KernelSU|ksud|machikado|inject' | tail -120

echo "########## [6] KSU interface probes ##########"
echo "--- /dev/ksud ---"; ls -la /dev/ksud 2>&1
echo "--- ksu proc/sysfs nodes ---"; ls -la /proc/ksu* /sys/module/kernelsu* 2>&1 | head -30
echo "--- ksud binary ---"; ls -la /data/adb/ksud /data/adb/ksu/bin/ 2>&1

echo "########## [7] tombstones (recent) ##########"
ls -lat /data/tombstones/ 2>&1 | head -15

echo "########## [8] SELinux context of our processes ##########"
for p in $(pidof com.suw.manager); do echo "suw pid=$p ctx=$(cat /proc/$p/attr/current 2>/dev/null)"; done
echo "self ctx=$(cat /proc/self/attr/current 2>/dev/null)"
echo "===== DONE"
