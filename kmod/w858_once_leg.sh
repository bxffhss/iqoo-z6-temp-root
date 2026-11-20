#!/system/bin/sh
# w858: before/after witness for the "open Manager exactly once, no force-stop" control
PH="$1"
echo "W858 PH=$PH up=$(cut -d' ' -f1 /proc/uptime)"
echo "MPID=$(pidof me.weishu.kernelsu)"
for P in 971 981; do
  echo "P$P state=$(cut -d' ' -f3 /proc/$P/stat 2>/dev/null) wchan=$(cat /proc/$P/wchan 2>/dev/null)"
done
echo "TOMB=$(ls /data/tombstones 2>/dev/null | grep -ac tombstone)"
echo "TOMB_NEW=$(ls -lt /data/tombstones 2>/dev/null | head -3 | tail -2 | awk '{print $6,$7,$8,$9}')"
echo "ANR_CT=$(dumpsys dropbox 2>/dev/null | grep -ac 'data_app_anr')"
echo "TOMBBOX=$(dumpsys dropbox 2>/dev/null | grep -ac 'SYSTEM_TOMBSTONE')"
echo "KILLSOFT=$(dmesg | grep -ac KILLSOFT)"
echo "SU0=$(dmesg | grep -ac 'SU0 su found')"
echo "FOCUS=$(dumpsys window 2>/dev/null | grep -a mCurrentFocus | tail -1)"
echo "W858 END up=$(cut -d' ' -f1 /proc/uptime)"
