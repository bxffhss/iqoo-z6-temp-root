#!/system/bin/sh
# w900p.sh — the payload handed to `su -c`. Prints WHO it became onto stdout (which the
# app driver captures), then probes the two write channels separately, because "couldn't
# create /data/local/tmp/..." is EACCES for BOTH root-in-the-app's-domain and plain-app-uid.
HA=/data/data/com.termux/files/home
echo "P0 via=$0 self=$(id)"
echo "P1 ctx=$(cat /proc/self/attr/current 2>&1)"
echo "P2 $(grep -a '^Uid:\|^CapEff:\|^Seccomp:' /proc/self/status 2>&1 | tr '\n' ' ')"
echo "P3 ksu_fd_line=$(ls -l /proc/self/fd 2>&1 | grep -c ksu)"
echo "P4 write into app HOME: $(echo ok > $HA/w900_rootseen.txt 2>&1; cat $HA/w900_rootseen.txt 2>&1)"
echo "P5 write into /data/local/tmp: $(echo ok > /data/local/tmp/w900_rootseen.txt 2>&1)"
echo "P6 getenforce=$(getenforce 2>&1) tool=$(command -v id 2>&1)"
echo "P7 proc_ksu_nodes=$(ls /proc 2>&1 | grep -c ksu) install_fd_node=$(ls -l /proc/ksu_install_fd 2>&1 | head -1)"
echo "P8 END"
