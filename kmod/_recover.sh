exec >/data/local/tmp/w_recover.out 2>&1
echo "id=$(id)"
echo "--- /data/adb/modules ---"; ls /data/adb/modules/ 2>&1
echo "--- zyxisksu files ---"; ls /data/adb/modules/zygisksu/ 2>&1 | head -4
echo "--- /data/adb/ksud ---"; ls -l /data/adb/ksud 2>&1
echo "--- proc/ksu_install_fd ---"; ls -l /proc/ksu_install_fd 2>&1
MP=$(pidof me.weishu.kernelsu)
echo "mgr_pid_before=$MP"
if [ -z "$MP" ]; then monkey -p me.weishu.kernelsu -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 5; MP=$(pidof me.weishu.kernelsu); fi
echo "mgr_pid=$MP"
for q in $MP; do echo "$q" > /proc/ksu_install_fd; echo "install $q rc=$?"; done
for q in $MP; do echo "mgr $q ksu_fd=$(ls -l /proc/$q/fd 2>/dev/null | grep -ac ksu_driver)"; done
echo "===== DONE ====="
