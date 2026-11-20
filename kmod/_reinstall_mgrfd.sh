exec >/data/local/tmp/w_rmf.out 2>&1
echo "id=$(id)"
for t in 1 2 3; do
  MP=$(pidof me.weishu.kernelsu); [ -n "$MP" ] && break
  monkey -p me.weishu.kernelsu -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 4
done
echo "mgr=$MP"
for q in $MP; do echo "$q" > /proc/ksu_install_fd; echo "install $q rc=$?"; done
echo "===== DONE ====="
