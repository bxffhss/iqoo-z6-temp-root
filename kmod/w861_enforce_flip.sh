#!/system/bin/sh
# w861: flip Permissive -> Enforcing (the last root leg of this window, by design)
echo "W861 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
echo "BEFORE_ENF=$(cat /sys/fs/selinux/enforce 2>&1) GET=$(/system/bin/getenforce 2>&1)"
echo 1 > /sys/fs/selinux/enforce
echo "WRITE_RC=$?"
echo "AFTER_ENF=$(cat /sys/fs/selinux/enforce 2>&1) GET=$(/system/bin/getenforce 2>&1)"
echo "DENIALS_IN_RING=$(dmesg 2>/dev/null | grep -ac 'avc:.*denied')"
echo "ID=$(id)"
echo "MOD=$(grep -c kernelsu /proc/modules)"
echo "MPID=$(pidof me.weishu.kernelsu)"
echo "ENF_READBACK=$(cat /sys/fs/selinux/enforce 2>&1)"
echo "W861 END up=$(cut -d' ' -f1 /proc/uptime)"
