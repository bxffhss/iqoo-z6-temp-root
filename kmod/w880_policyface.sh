#!/system/bin/sh
# w880: feasibility probe for #197 (can we obtain / replace the live SELinux policy?)
echo "W880 BEGIN up=$(cut -d' ' -f1 /proc/uptime)"
echo "CTX=$(cat /proc/self/attr/current 2>&1)"
echo "-- selinuxfs nodes"
for P in /sys/fs/selinux/enforce /sys/fs/selinux/load /sys/fs/selinux/policy /sys/fs/selinux/status; do
  if ls "$P" >/dev/null 2>&1; then echo "  OK   $P ($(ls -l $P 2>/dev/null | awk '{print $5}'))"; else echo "  DENY $P"; fi
done
echo "-- policy sources on disk (are they world-readable?)"
for P in /system/etc/selinux/plat_sepolicy.cil /system_ext/etc/selinux /vendor/etc/selinux /odm/etc/selinux /product/etc/selinux; do
  echo "  [$P]"; ls -l "$P" 2>&1 | head -8 | sed 's/^/     /'
done
echo "-- the big one: precompiled_sepolicy"
ls -l /vendor/etc/selinux/precompiled_sepolicy* /dev/selinux 2>&1 | head -6
echo "-- our own ko's ioctl face: does GET_SEPOLICY-ish node exist?"
ls /proc | grep -a ksu
echo "W880 END up=$(cut -d' ' -f1 /proc/uptime)"
