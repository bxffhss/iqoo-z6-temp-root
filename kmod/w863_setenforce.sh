#!/system/bin/sh
# w863: set enforcing to $1 (0/1) and read it back. Usage: sh w863_setenforce.sh 0|1
T="$1"
echo "W863 BEGIN up=$(cut -d' ' -f1 /proc/uptime) want=$T"
echo "BEFORE=$(cat /sys/fs/selinux/enforce 2>&1)"
echo "$T" > /sys/fs/selinux/enforce
echo "WRITE_RC=$?"
echo "AFTER=$(cat /sys/fs/selinux/enforce 2>&1) GET=$(/system/bin/getenforce 2>&1)"
echo "ID=$(id)"
echo "DENIALS=$(dmesg 2>/dev/null | grep -ac 'avc:.*denied')"
echo "MPID=$(pidof me.weishu.kernelsu)"
echo "W863 END up=$(cut -d' ' -f1 /proc/uptime)"
