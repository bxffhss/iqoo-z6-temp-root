#!/system/bin/sh
# w901_appleg.sh — one leg only: hand the root child w901p.sh and let it describe itself.
HA=/data/data/com.termux/files/home
A=$HA/w901_app.out
{
  echo "A0 date=$(date) baseline=$(id)"
} > $A 2>&1
/system/bin/su -c /data/local/tmp/w901p.sh >> $A 2>&1
echo "A1 rc=$?" >> $A 2>&1
echo "A2 END date=$(date)" >> $A 2>&1
