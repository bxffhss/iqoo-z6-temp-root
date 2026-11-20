#!/system/bin/sh
# w877: install the driver fd into the ALREADY-RUNNING granted app (uid 10667) via /proc/ksu_install_fd
# Purpose: separate "no fd" from "wrong socket name" / "arg contract" for the app-facing su.
echo "W877 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
echo "ENF=$(cat /sys/fs/selinux/enforce) ID=$(id)"
P=$(dumpsys activity processes 2>/dev/null | grep -aoE "[0-9]+:com.termux/u0a667" | head -1 | cut -d: -f1)
echo "TERMUX_PID=[$P]"
if [ -n "$P" ]; then
  echo "NODE=$(ls -l /proc/ksu_install_fd 2>&1 | tail -1)"
  echo "$P" > /proc/ksu_install_fd
  echo "WRITE_RC=$?"
  sleep 1
  echo "-- KSUFDINST witnesses in ring (last 4)"
  dmesg 2>/dev/null | grep -a KSUFDINST | tail -4
  echo "RING_LAST=$(dmesg 2>/dev/null | tail -1)"
else
  echo "SKIP=没拿到 termux pid(未测)"
fi
echo "W877 END up=$(cut -d' ' -f1 /proc/uptime)"
