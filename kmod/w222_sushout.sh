#!/system/bin/sh
L=/data/local/tmp/w222_sushout.out
exec >>"$L" 2>&1
echo "=== W222 读 suw 自己的 su 自检 up=$(cut -d' ' -f1 /proc/uptime) enf=$(cat /sys/fs/selinux/enforce 2>&1) ==="
for f in /data/local/tmp/ksu_grant.txt /data/data/com.suw.manager/files/ksu_grant.txt; do
    echo "--- $f ---"; ls -l "$f" 2>&1; tail -14 "$f" 2>&1
done
echo "=== DONE ==="
chmod 666 "$L" 2>/dev/null
