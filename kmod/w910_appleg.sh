#!/system/bin/sh
# w910_appleg.sh — Y1 then Y2 use the SAME literal a second time in the same shell; Y3 is a child
# shell; Y4 is the file named "su". If Y1 works and Y2 dies, 改道 is one-shot per path string
# (the ko hands the nested execve an "empty path", so the caller's own string gets used up).
HA=/data/data/com.termux/files/home
A=$HA/w910_app.out
{ echo "Y0 date=$(date)"; } > $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "Y1 first use rc=$?" >> $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "Y2 second use, same shell, same literal rc=$?" >> $A 2>&1
/system/bin/sh -c '/system/bin/su -c id' >> $A 2>&1
echo "Y3 child sh -c rc=$?" >> $A 2>&1
/data/data/com.termux/files/usr/bin/su -c id >> $A 2>&1
echo "Y4 the file named su rc=$?" >> $A 2>&1
/system/bin/sh $HA/w910b.sh >> $A 2>&1
echo "Y5 fresh child sh running its own script rc=$?" >> $A 2>&1
echo "Y6 END date=$(date)" >> $A 2>&1
