#!/system/bin/sh
# w857: A/B on SD1 semantics (does it fire on ANY execve, or only su-path execves?)
echo "W857 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
kill 32259 2>/dev/null; echo "KILL_RC=$?"
sleep 6
C1=$(dmesg | grep -ac 'SD1 decline')
echo "C1=$C1 up=$(cut -d' ' -f1 /proc/uptime)"
I=0
while [ $I -lt 25 ]; do
  /system/bin/true
  I=$((I + 1))
done
C2=$(dmesg | grep -ac 'SD1 decline')
echo "C2=$C2  after25_true  delta_ab=$(($C2 - $C1))"
sleep 6
C3=$(dmesg | grep -ac 'SD1 decline')
echo "C3=$C3  idle6s_after  delta_idle=$(($C3 - $C2))"
echo "FOLLOWER_ALIVE=$(pidof -s 32259 2>/dev/null) PS=$(ps -A 2>/dev/null | grep -ac 32259)"
echo "DMESG2_MTIME=$(ls -l --time-style=+%H:%M:%S /data/local/tmp/dmesg2.log 2>&1 | tail -1)"
echo "SU_TOKENS SU0=$(dmesg | grep -ac 'SU0 su found') SD4=$(dmesg | grep -ac 'SD4 su') SD3=$(dmesg | grep -ac 'SD3 decline')"
echo "-- post-kill background sample (20s)"
echo "CPU1=$(grep -a '^cpu ' /proc/stat)"
echo "PR1=$(grep -a '^processes' /proc/stat) CT1=$(grep -a '^ctxt' /proc/stat)"
sleep 20
echo "CPU2=$(grep -a '^cpu ' /proc/stat)"
echo "PR2=$(grep -a '^processes' /proc/stat) CT2=$(grep -a '^ctxt' /proc/stat)"
echo "W857 END up=$(cut -d' ' -f1 /proc/uptime)"
