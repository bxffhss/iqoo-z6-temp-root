#!/system/bin/sh
# w924_appleg.sh — #209 mechanism matrix. Host = run-as com.termux (uid 10667, in the allowlist,
# domain runas_app, Permissive segment). ASCII-only artifact on purpose: adb shell cat of a file
# containing CJK gets swallowed by our own tooling (env gotcha), so the labels must not be CJK.
# Cells: A1/A9 direct su (known good) | A2 child sh -c (known rc=127) | A3 env (raw execve)
# A4 child sh with exec builtin | A6 child execs an existing binary (control)
# A7 direct exec of the redirect target itself | A8 child shell execs the redirect target
# B1 try to pull the kernel ring through the root channel (multi-word -c = #208 contract)
HA=/data/data/com.termux/files/home
A=$HA/w924.out

U() { cut -d' ' -f1 /proc/uptime; }

{
  echo "H0 date=$(date) up=$(U)"
  echo "H1 id=[$(id)]"
  echo "H2 ctx=[$(cat /proc/self/attr/current 2>&1)]"
  echo "H3 seccomp=[$(grep -a -E 'Seccomp|NoNewPrivs' /proc/self/status 2>&1 | tr '\n' ' ')]"
  echo "H4 enf=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -c '^kernelsu ' /proc/modules 2>&1)"
  echo "H5 kd=$(/system/bin/ls -l /data/local/tmp/kd 2>&1 | /system/bin/awk '{print $1,$3,$5}')"
} > $A 2>&1

echo "A1_BEGIN direct up=$(U)" >> $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "A1 rc=$? up=$(U)" >> $A 2>&1

echo "A2_BEGIN child bare up=$(U)" >> $A 2>&1
/system/bin/sh -c '/system/bin/su -c id' >> $A 2>&1
echo "A2 rc=$? up=$(U)" >> $A 2>&1

echo "A3_BEGIN env up=$(U)" >> $A 2>&1
/system/bin/env /system/bin/su -c id >> $A 2>&1
echo "A3 rc=$? up=$(U)" >> $A 2>&1

echo "A4_BEGIN child exec builtin up=$(U)" >> $A 2>&1
/system/bin/sh -c 'exec /system/bin/su -c id' >> $A 2>&1
echo "A4 rc=$? up=$(U)" >> $A 2>&1

echo "A6_BEGIN child execs existing binary (control) up=$(U)" >> $A 2>&1
/system/bin/sh -c '/system/bin/toybox id' >> $A 2>&1
echo "A6 rc=$? up=$(U)" >> $A 2>&1

echo "A7_BEGIN direct exec of redirect target kd up=$(U)" >> $A 2>&1
/data/local/tmp/kd -c id >> $A 2>&1
echo "A7 rc=$? up=$(U)" >> $A 2>&1

echo "A8_BEGIN child shell execs kd up=$(U)" >> $A 2>&1
/system/bin/sh -c '/data/local/tmp/kd -c id' >> $A 2>&1
echo "A8 rc=$? up=$(U)" >> $A 2>&1

echo "A9_BEGIN direct again (same-window control) up=$(U)" >> $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "A9 rc=$? up=$(U)" >> $A 2>&1

echo "B1_BEGIN ring via root channel, multiword -c up=$(U)" >> $A 2>&1
/system/bin/su -c 'dmesg -t > /data/data/com.termux/files/home/w924_ring.txt' >> $A 2>&1
echo "B1 rc=$? ring=$(/system/bin/ls -l $HA/w924_ring.txt 2>&1 | /system/bin/awk '{print $5}')" >> $A 2>&1

echo "B2_BEGIN ring via root channel, single word -c up=$(U)" >> $A 2>&1
/system/bin/su -c dmesg > $HA/w924_b2.txt 2>> $A
echo "B2 rc=$? bytes=$(/system/bin/ls -l $HA/w924_b2.txt 2>&1 | /system/bin/awk '{print $5}') ksubeat=$(/system/bin/grep -ac KSUBEAT $HA/w924_b2.txt 2>&1)" >> $A 2>&1

echo "BZ_END date=$(date) up=$(U)" >> $A 2>&1
