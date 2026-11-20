#!/system/bin/sh
# w898p.sh — ROOT-side witness. Executed BY the su child, appends to a shell_data_file
# the app itself cannot write, so "no output on the app terminal" can no longer be
# confused with "the leg never ran". Tag = its own filename (4 copies run as B/C/D/E).
F=/data/local/tmp/w898_root.txt
{
  echo "== via=$0 up=$(cut -d' ' -f1 /proc/uptime) date=$(date)"
  echo "id=$(id)"
  echo "uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>&1) prev=$(cat /proc/self/attr/prev 2>&1)"
  echo "seccomp=$(grep -a '^Seccomp:' /proc/self/status 2>&1) caps=$(grep -a '^CapEff:' /proc/self/status 2>&1)"
  echo "ksu_fd=$(ls -l /proc/self/fd 2>/dev/null | grep -c ksu)"
  echo "-- can we see the app terminal? (#116 write-back channel)"
  ls -lZ /dev/pts/ 2>&1 | head -6
  echo "-- can root unlink its own witness dir entry?"
  ls -l /data/local/tmp/kd 2>&1 | head -2
  echo "END via=$0"
} >> $F 2>&1
