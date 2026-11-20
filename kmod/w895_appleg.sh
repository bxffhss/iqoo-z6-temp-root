#!/system/bin/sh
# w895_appleg.sh — runs as the GRANTED APP (uid 10667, domain untrusted_app, seccomp ON)
# every case prints its own errno/rc so we can see WHERE the refusal happens
O=/data/data/com.termux/files/home/w895.out
{
  echo "W895 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
  echo "ID=$(id)"
  echo "CTX=$(cat /proc/self/attr/current 2>&1)"
  echo "SECCOMP=$(grep -a Seccomp: /proc/self/status 2>&1)"
  echo "FD_KSU=$(ls -l /proc/self/fd 2>/dev/null | grep -ac ksu_driver)"
  echo "-- stat the redirect target"
  ls -lZ /data/local/tmp/kd 2>&1 | head -2
  echo "-- case A: exec the target DIRECTLY (no 改道 involved)"
  /data/local/tmp/kd -c id 2>&1 | head -3
  echo "   rcA=$?"
  echo "-- case B: the su path (ko should rewrite it to the target)"
  /system/bin/su -c id 2>&1 | head -3
  echo "   rcB=$?"
  echo "-- case C: bare su with stdin closed (what an interactive shell does)"
  echo | /system/bin/su 2>&1 | head -3
  echo "   rcC=$?"
  echo "-- case D: does the app own-copy execute? (label/mount axis)"
  cp /data/local/tmp/kd /data/data/com.termux/files/home/kdcopy 2>&1 | head -2
  chmod 700 /data/data/com.termux/files/home/kdcopy 2>&1
  ls -lZ /data/data/com.termux/files/home/kdcopy 2>&1 | head -2
  /data/data/com.termux/files/home/kdcopy -c id 2>&1 | head -3
  echo "   rcD=$?"
  echo "-- case E: write witness into /data/local/tmp (why the earlier redirect was refused)"
  echo x > /data/local/tmp/w895_probe.txt 2>&1
  echo "   rcE=$?"
  echo "W895 END up=$(cut -d' ' -f1 /proc/uptime)"
} > "$O" 2>&1
