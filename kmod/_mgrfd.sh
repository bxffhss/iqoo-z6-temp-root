exec >/data/local/tmp/w_mgrfd.out 2>&1
echo "id=$(id)"
MP=$(pidof me.weishu.kernelsu)
echo "mgr_before=$MP"
if [ -z "$MP" ]; then monkey -p me.weishu.kernelsu -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 6; MP=$(pidof me.weishu.kernelsu); fi
echo "mgr=$MP"
for q in $MP; do echo "$q" > /proc/ksu_install_fd; echo "install $q rc=$?"; done
for q in $MP; do echo "mgr $q ksu_fd=$(ls -l /proc/$q/fd 2>/dev/null | grep -ac ksu_driver)"; done
echo "===== DONE ====="
