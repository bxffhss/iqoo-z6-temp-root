#!/system/bin/sh
# w900_appleg.sh — runs as the GRANTED APP (uid 10667, untrusted_app_25, Enforcing).
# Everything a case prints lands in $A (its own stdout/stderr), and each case's identity
# witness is `id` itself, not a file permission. Refusal, root-in-own-domain and
# root-in-shell-domain produce three different texts here.
HA=/data/data/com.termux/files/home
A=$HA/w900_app.out
P=/data/local/tmp
{
  echo "A0 BEGIN date=$(date) up=$(cut -d' ' -f1 /proc/uptime 2>&1)"
  echo "A1 baseline self=$(id)"
  echo "A2 ctx=$(cat /proc/self/attr/current 2>&1)"
  echo "A3 path_su=$(command -v su 2>&1)"
  echo "A4 ksu_fd=$(ls -l /proc/self/fd 2>&1 | grep -c ksu)"
} > $A 2>&1

echo "--- G 改道: /system/bin/su -c id" >> $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "G rc=$?" >> $A 2>&1

echo "--- H 改道: /system/bin/su -c $P/w900pH.sh" >> $A 2>&1
/system/bin/su -c $P/w900pH.sh >> $A 2>&1
echo "H rc=$?" >> $A 2>&1

echo "--- I the /product/bin bind: /product/bin/su -c $P/w900pI.sh" >> $A 2>&1
/product/bin/su -c $P/w900pI.sh >> $A 2>&1
echo "I rc=$?" >> $A 2>&1

echo "--- J piped interactive into 改道 su" >> $A 2>&1
printf 'sh %s/w900pJ.sh\nexit\n' "$P" | /system/bin/su >> $A 2>&1
echo "J rc=$?" >> $A 2>&1

echo "--- K bare su from PATH (this app ships its own su)" >> $A 2>&1
su -c $P/w900pK.sh >> $A 2>&1
echo "K rc=$?" >> $A 2>&1

echo "--- L what does bare su claim to be? su -v" >> $A 2>&1
su -v >> $A 2>&1
echo "L rc=$?" >> $A 2>&1

{
  echo "A9 END date=$(date) id_after=$(id)"
  echo "A10 app can see the root-side probe files: $(ls -l $A $HA/w900_rootseen.txt $P/w900_rootseen.txt 2>&1 | tr '\n' '|')"
} >> $A 2>&1
