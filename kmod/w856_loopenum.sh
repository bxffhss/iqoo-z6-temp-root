#!/system/bin/sh
# w856: name the root loop (read only)
echo "W856 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
for P in 32259 26835; do
  echo "P=$P CMD=[$(tr -d '\000' < /proc/$P/cmdline 2>/dev/null)] STATE=$(cut -d' ' -f3 /proc/$P/stat 2>/dev/null) PP=$(cut -d' ' -f4 /proc/$P/stat 2>/dev/null)"
done
echo "-- ancestry walk from 32259"
C=32259
I=0
while [ $I -lt 6 ]; do
  [ -r /proc/$C/stat ] || break
  PP=$(cut -d' ' -f4 /proc/$C/stat)
  CMD=$(tr -d '\000' < /proc/$C/cmdline 2>/dev/null)
  echo "  $C ppid=$PP cmd=[$CMD]"
  C=$PP
  I=$((I+1))
done
echo "-- every sh/sleep/su task"
ps -A -o PID,PPID,USER,STAT,ARGS | grep -aE "(^| )(sh|su|sleep|busybox|toybox)( |$)" | head -16
echo "-- how many tasks total, and root-user count"
echo "TOTAL=$(ps -A 2>/dev/null | wc -l)"
echo "-- 3 consecutive ring tails (who is exec'ing)"
J=0
while [ $J -lt 3 ]; do
  dmesg | tail -1
  sleep 1
  J=$((J+1))
done
echo "W856 END up=$(cut -d' ' -f1 /proc/uptime)"
