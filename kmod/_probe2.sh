exec >/data/local/tmp/w_probe2.out 2>&1
echo id=$(id)
echo --- modules ---
ls /data/adb/modules/ 2>&1
echo --- zyxisksu ---
ls /data/adb/modules/zygisksu/ 2>&1 | head -4
