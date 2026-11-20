#!/system/bin/sh
# w908_appleg.sh — why did `exec /system/bin/su` from inside a file *named su* fall to ENOENT
# while the same execve from w900_appleg.sh gave uid=0? Four shapes, one run. Control P1 is the
# known-good baseline, so any difference in P2..P4 is about the caller, not about 改道 itself.
HA=/data/data/com.termux/files/home
A=$HA/w908_app.out
SUDIR=/data/data/com.termux/files/usr/bin/su
{
  echo "P0 date=$(date) up=$(cat /proc/uptime 2>&1 | cut -d' ' -f1)"
  echo "P0b su_candidate=$(command -v su 2>&1) md5=$(md5sum $(command -v su) 2>&1)"
} > $A 2>&1

echo "--- P1 control: /system/bin/su -c id (this one gave uid=0 in w900)" >> $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "P1 rc=$?" >> $A 2>&1

echo "--- P2 the su-NAMED script doing exec /system/bin/su (the failing forwarder)" >> $A 2>&1
$SUDIR -c id >> $A 2>&1
echo "P2 rc=$?" >> $A 2>&1

echo "--- P3 same job via an intermediate sh whose own name is not su" >> $A 2>&1
/system/bin/sh -c '/system/bin/su "$@"' z6su -c id >> $A 2>&1
echo "P3 rc=$?" >> $A 2>&1

echo "--- P4 exec the redirect target directly (bypasses 改道, so no fd install?)" >> $A 2>&1
/data/local/tmp/kd -c id >> $A 2>&1
echo "P4 rc=$?" >> $A 2>&1

echo "--- P5 what does P3's caller look like? comm/exe of this script" >> $A 2>&1
{ echo "P5a comm=$(cat /proc/self/comm 2>&1) exe=$(ls -l /proc/self/exe 2>&1 | cut -d'>' -f2-)"; } >> $A 2>&1
echo "P6 END date=$(date)" >> $A 2>&1
