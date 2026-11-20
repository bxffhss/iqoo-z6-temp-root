#!/system/bin/sh
# w847: root leg driven from PC (run-as com.termux -> /system/bin/su 改道)
echo "W847 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
echo "WHO=$(id)"
echo "MOD=$(grep -a kernelsu /proc/modules)"
echo "-- ring coverage"
dmesg > /dev/null 2>&1 || echo "DMESG_FAIL=$?"
N=$(dmesg 2>/dev/null | wc -l)
echo "RING_LINES=$N"
echo "RING_FIRST=$(dmesg 2>/dev/null | head -1 | cut -c1-40)"
echo "RING_LAST=$(dmesg 2>/dev/null | tail -1 | cut -c1-40)"
echo "-- token counts inside visible ring"
for T in KILLSOFT KILLGUARD KSUBIRTH KSUBEAT SD1 dispatch; do
  echo "TOK $T = $(dmesg 2>/dev/null | grep -ac "$T")"
done
echo "-- last KILLSOFT lines"
dmesg 2>/dev/null | grep -a KILLSOFT | tail -4
echo "-- last KILLGUARD lines"
dmesg 2>/dev/null | grep -a KILLGUARD | tail -4
echo "-- fs/pstore"
ls -l /sys/fs/pstore 2>&1 | head -4
echo "-- /data/adb"
ls -lR /data/adb 2>&1 | head -20
echo "-- tombstones"
ls /data/tombstones 2>&1 | wc -l
echo "-- ksu proc nodes"
ls /proc 2>/dev/null | grep -a ksu
echo "-- allowlist file"
ls -l /data/adb/ksu/.allowlist 2>&1
echo "W847 END up=$(cut -d' ' -f1 /proc/uptime)"
