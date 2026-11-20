#!/system/bin/sh
# w217_postkick_diag.sh — 踢后诊断：daemon 死因 / root 腿可否恢复 / 注入是否残留
# 纯 shell 只读（root 腿可能已断）
OUT=/data/local/tmp/w217_diag.out
exec >"$OUT" 2>&1
echo "ts=$(date +%Y-%m-%dT%H:%M:%S)"

echo "########## [1] full process snapshot (all uid=0 + zygisk/lspd/ksu) ##########"
ps -A -o PID,PPID,UID,NAME 2>/dev/null | grep -aE ' (0|root) |zygisk|lspd|lsposed|zn-|ksu|shd|suw|manager|app_process' | head -60
echo "--- full ps count ---"; ps -A 2>/dev/null | wc -l

echo "########## [2] kernel-side still alive? ##########"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
echo "up=$(cut -d' ' -f1 /proc/uptime) boot_completed=$(getprop sys.boot_completed)"
echo "enf=$(cat /sys/fs/selinux/enforce) mod=$(grep -c kernelsu /proc/modules)"
echo "--- /dev/ksud + su ---"; ls -la /dev/ksud /product/bin/su 2>&1
echo "--- ksu proc nodes ---"; ls -la /proc/ksu* 2>&1
echo "--- ksu_race_fd switch ---"; ls -la /data/local/tmp/ksu_race_fd 2>&1
echo "--- allowlist (would pollute next shot) ---"; ls -la /data/adb/ksu/.allowlist 2>&1

echo "########## [3] did daemon write abort_msg? (SIGKILL vs self-abort) ##########"
ls -la /data/adb/zygisksu/ 2>&1
echo "--- .abort_msg ---"; cat /data/adb/zygisksu/.abort_msg 2>&1; echo
echo "--- .magic ---"; cat /data/adb/zygisksu/.magic 2>&1; echo

echo "########## [4] unix sockets (any zn/lspd leftovers?) ##########"
grep -aE 'zn_|lspd|lspbridge|zygisk' /proc/net/unix 2>/dev/null | head -30
echo "socket_count=$(grep -acE 'zn_|lspd|lspbridge|zygisk' /proc/net/unix 2>/dev/null)"

echo "########## [5] logcat: framework restart + daemon death (broad) ##########"
logcat -d -t 3000 2>/dev/null | grep -aiE 'zn-daemon|ZygiskNext|zygisk|lspd|LSPosed|KernelSU|ksud|libksud|watchdog|system_server|zygote.*restart|Watchdog|killProcessGroup|lmkd|lowmemorykiller|ProcessRecord|am_proc_died|boot_completed' | tail -120

echo "########## [6] ★root leg recovery test: can we start suw + is su usable? ##########"
echo "--- suw pid before ---"; pidof com.suw.manager
echo "--- try am start suw (harmless, no cmd) ---"
am start -f 0x4000000 -n com.suw.manager/.MainActivity 2>&1 | head -5
sleep 3
echo "--- suw pid after ---"; pidof com.suw.manager
echo "--- shell su test ---"
/product/bin/su -c id 2>&1 | head -3
echo "--- ksuctl88 info (if present) ---"
ls -la /data/local/tmp/ksuctl88 2>&1
timeout 5 /data/local/tmp/ksuctl88 info 2>&1 | head -5

echo "########## [7] LSPosed Manager activation UI state (am/dumpsys) ##########"
echo "--- LSPosed manager installed? ---"
pm list packages 2>/dev/null | grep -aiE 'lsposed|weishu|suw'
echo "--- service list serial (Z5 判据) ---"
timeout 10 service list 2>/dev/null | grep -aiE 'serial|lspd|lsposed'
echo "--- lspd log newest ---"
ls -lat /data/adb/lspd/log/ 2>/dev/null | head -10

echo "########## [8] zygote restart proof + new zygote env ##########"
echo "zygote64=$(pidof zygote64) start_ticks=$(awk '{print $22}' /proc/$(pidof zygote64)/stat 2>/dev/null)"
echo "zygote=$(pidof zygote) system_server=$(pidof system_server)"
echo "--- zygote cmdline ---"; cat /proc/$(pidof zygote64)/cmdline 2>/dev/null | tr '\0' ' '; echo
echo "--- zygote environ (ZYGISK related) ---"; grep -az 'ZYGISK' /proc/$(pidof zygote64)/environ 2>/dev/null
echo "===== DONE"
