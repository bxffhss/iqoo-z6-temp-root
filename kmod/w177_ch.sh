#\!/system/bin/sh
exec >>/data/local/tmp/w177_ch.out 2>&1
echo "=== chmod 补刀 ==="
chmod 666 /data/local/tmp/pp_su.txt; echo "chmod rc=$?"
ls -l /data/local/tmp/pp_su.txt
echo "===== DONE ====="
