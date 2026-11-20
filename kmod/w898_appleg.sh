#!/system/bin/sh
# w898_appleg.sh — runs in the GRANTED APP's own domain (uid 10667, untrusted_app_25, Enforcing).
# Question #206: when `su` prints NOTHING on the app terminal, was the leg refused,
# or did it really give root whose stdout just can't reach this terminal (#116)?
# So: never trust the screen. Each case hands root a script whose own witness file
# lives in /data/local/tmp (root can write it, this app cannot) => a refusal and a
# silent success produce different artifacts.
HA=/data/data/com.termux/files/home
A=$HA/w898_app.out          # app-domain side
F=/data/local/tmp/w898_root.txt   # root-domain side (4 payload copies append here)
{
  echo "A0 BEGIN up=$(cut -d' ' -f1 /proc/uptime) date=$(date)"
  echo "A1 id=$(id)"
  echo "A2 ctx=$(cat /proc/self/attr/current 2>&1)"
  echo "A3 $(grep -a '^Seccomp:' /proc/self/status 2>&1)"
  echo "A4 ksu_fd=$(ls -l /proc/self/fd 2>/dev/null | grep -c ksu)"
  echo "A5 path_su=$(command -v su 2>&1)"
  echo "A6 ls /system/bin/su => $(ls -l /system/bin/su 2>&1)"
  echo "A7 ls /product/bin/su => $(ls -l /product/bin/su 2>&1)"
  echo "A8 can this app read the root witness? => $(cat $F 2>&1 | head -1)"
} > $A 2>&1

/system/bin/su -c /data/local/tmp/w898pB.sh >> $A 2>&1
echo "B rc=$? (改道 leg, -c one word)" >> $A 2>&1

/product/bin/su -c /data/local/tmp/w898pC.sh >> $A 2>&1
echo "C rc=$? (static su in the /product/bin bind)" >> $A 2>&1

printf 'sh /data/local/tmp/w898pD.sh\nexit\n' | /system/bin/su >> $A 2>&1
echo "D rc=$? (piped interactive)" >> $A 2>&1

su -c /data/local/tmp/w898pE.sh >> $A 2>&1
echo "E rc=$? (bare su from PATH)" >> $A 2>&1

{
  echo "A9 END up=$(cut -d' ' -f1 /proc/uptime) id_after=$(id)"
  echo "A10 root witness bytes as seen by app => $(wc -c < $F 2>&1)"
} >> $A 2>&1
