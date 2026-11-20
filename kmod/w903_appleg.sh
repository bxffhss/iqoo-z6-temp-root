#!/system/bin/sh
# w903_appleg.sh — one leg: let the root leg remove the root-owned residue I left in /data/local/tmp.
A=/data/data/com.termux/files/home/w903_app.out
/system/bin/su -c /data/local/tmp/w903clean.sh > $A 2>&1
echo "rc=$?" >> $A 2>&1
