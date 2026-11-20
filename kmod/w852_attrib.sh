#!/system/bin/sh
# w852: attribute the uid=0 su-decline loop + read Manager's root shells
echo "W852 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
for P in 971 981 25281 445; do
  echo "--- pid=$P"
  echo "CMD=$(tr -d '\0' < /proc/$P/cmdline 2>/dev/null)"
  echo "STAT=$(cat /proc/$P/stat 2>/dev/null | cut -d' ' -f1-6,14,15,22)"
  echo "UID=$(grep -a Uid: /proc/$P/status 2>/dev/null)"
  echo "FD_KSU=$(ls -l /proc/$P/fd 2>/dev/null | grep -ac ksu_driver)"
  echo "FD_N=$(ls /proc/$P/fd 2>/dev/null | wc -w)"
  echo "FDSOCK=$(ls -l /proc/$P/fd 2>/dev/null | grep -ac socket)"
done
echo "--- children of 981 / 971 (two samples 6s apart)"
C1=$(cat /proc/stat | grep -a '^processes')
echo "PROC1=$C1"
sleep 6
C2=$(cat /proc/stat | grep -a '^processes')
echo "PROC2=$C2"
echo "SD1_TAIL=$(dmesg | grep -ac 'SD1 decline')"
echo "--- ppid walk for last 3 decline pids"
dmesg | grep -a 'F2 redirect' | tail -3 | while read L; do
  P=$(echo "$L" | grep -ao 'pid=[0-9]*' | cut -d= -f2)
  [ -r /proc/$P/stat ] && echo "P=$P PP=$(cut -d' ' -f4 /proc/$P/stat) CMD=$(tr -d '\0' < /proc/$P/cmdline)"
done
echo "W852 END up=$(cut -d' ' -f1 /proc/uptime)"
