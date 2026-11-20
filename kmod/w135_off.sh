#!/system/bin/sh
# w135_off.sh —— 收尾：**先 root 侧 umount 成功，再删源目录**(顺序反了就会把挂载点弄成指向已删目录)
L=/data/local/tmp/w135_off.out
{
echo "=== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
i=1
while [ $i -le 5 ]; do
    grep -aq pbin /proc/self/mountinfo || break
    umount /product/bin >/dev/null 2>&1; echo "umount#$i rc=$?"
    i=$((i+1))
done
echo "MOUNT_LEFT=$(grep -ac pbin /proc/self/mountinfo)"
echo "N=$(ls -A /product/bin | wc -l) (期望 3)"
echo "SU_GONE=$(ls -l /product/bin/su 2>&1)"
rm -rf /data/local/tmp/pbin /data/local/tmp/newbin /data/local/tmp/subin && echo "RM_DIRS_OK"
echo "SVC=$(runcon u:r:shell:s0 service list 2>/dev/null | head -1)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
