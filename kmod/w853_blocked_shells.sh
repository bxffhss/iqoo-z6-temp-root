#!/system/bin/sh
# w853: where are the Manager root shells blocked (read only)
echo "W853 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
for P in 971 981; do
  echo "--- pid=$P state=$(cut -d' ' -f3 /proc/$P/stat) wchan=$(cat /proc/$P/wchan 2>/dev/null)"
  grep -aE "^(State|Threads|SigPnd|SigBlk|Seccomp)" /proc/$P/status 2>/dev/null
  echo "TASKS=$(ls /proc/$P/task 2>/dev/null | tr '\n' ' ')"
  for T in $(ls /proc/$P/task 2>/dev/null); do
    echo "  T=$T state=$(cut -d' ' -f3 /proc/$P/task/$T/stat 2>/dev/null) wchan=$(cat /proc/$P/task/$T/wchan 2>/dev/null)"
  done
done
echo "STACK981="
cat /proc/981/stack 2>&1 | head -8
echo "--- who is exec'ing now (sample 2 ring reads 5s apart)"
echo "R1=$(dmesg | tail -1)"
sleep 5
echo "R2=$(dmesg | tail -1)"
echo "SD1_now=$(dmesg | grep -ac 'SD1 decline')"
echo "PROC_now=$(grep -a '^processes' /proc/stat)"
echo "W853 END up=$(cut -d' ' -f1 /proc/uptime)"
