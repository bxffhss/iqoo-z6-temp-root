#!/system/bin/sh
# w867: state of the su-bearing pieces, right now (run as root via 改道)
echo "W867 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
echo "NOW_EPOCH=$(date +%s)  BOOT_EPOCH=$(( $(date +%s) - $(cut -d' ' -f1 /proc/uptime | cut -d. -f1) ))"
echo "ENF=$(cat /sys/fs/selinux/enforce) MOD=$(grep -c kernelsu /proc/modules)"
echo "-- mount lines mentioning pbin / product/bin (root ns)"
grep -a "pbin\|/product/bin" /proc/self/mountinfo | head -4
echo "PBIN_COUNT=$(grep -ac pbin /proc/self/mountinfo)"
echo "-- /product/bin/su as root"
ls -l /product/bin/su 2>&1 | head -2
md5sum /product/bin/su 2>&1 | head -1
echo "-- source still there?"
ls -l /data/adb/ksu/pbin 2>&1 | head -4
ls -l /data/adb/ksu/.allowlist 2>&1 | head -1
echo "-- termux process fds (pid 6420) and its birth state"
for T in 6420; do
  echo "T=$T uid=$(grep -a Uid: /proc/$T/status 2>/dev/null | cut -f2) state=$(cut -d' ' -f3 /proc/$T/stat 2>/dev/null)"
  echo "FD_KSU=$(ls -l /proc/$T/fd 2>/dev/null | grep -ac ksu_driver) FD_N=$(ls /proc/$T/fd 2>/dev/null | wc -w)"
done
echo "-- any ksu_driver fd anywhere in the box (single ls over glob)"
ls -l /proc/[0-9]*/fd 2>/dev/null | awk '/^\/proc.*:$/{p=$1} /ksu_driver/{print p}' | sort -u | head -20
echo "HOLDER_LINES=$(ls -l /proc/[0-9]*/fd 2>/dev/null | grep -ac ksu_driver)"
echo "-- abstract sockets of ours"
cat /proc/net/unix 2>/dev/null | grep -a "suwshd\|sushd\|ksu" | head -4
echo "-- our daemons"
ps -A -o PID,PPID,USER,STAT,ARGS 2>/dev/null | grep -aE "ksuctl|shd" | grep -av "\[" | head -6
echo "W867 END up=$(cut -d' ' -f1 /proc/uptime)"
