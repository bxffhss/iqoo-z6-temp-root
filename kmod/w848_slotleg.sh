#!/system/bin/sh
# w848: read the ko's own /proc witnesses + name the su-hammerer
echo "W848 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
echo "-- ksu_slots (read only)"
cat /proc/ksu_slots 2>&1 | head -20
echo "-- ksu_install_fd (read only, no write)"
cat /proc/ksu_install_fd 2>&1 | head -6
echo "-- SD1 raw shape (last 3)"
dmesg | grep -a SD1 | tail -3
echo "-- KSUBEAT raw shape (last 3)"
dmesg | grep -a KSUBEAT | tail -3
echo "-- dispatch raw shape (last 2)"
dmesg | grep -a dispatch | tail -2
echo "W848 END up=$(cut -d' ' -f1 /proc/uptime)"
