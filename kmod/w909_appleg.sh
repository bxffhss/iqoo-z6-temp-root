#!/system/bin/sh
# w909_appleg.sh — the guard hypothesis: 改道 declines when the CALLING process's argv[0]
# contains "su" (anti-recursion). P1 control passes; P2/P3 failed with argv[0] holding "su".
# Q1/Q2 repeat the same nested-sh shape with argv[0] that has no "su" substring.
HA=/data/data/com.termux/files/home
A=$HA/w909_app.out
{ echo "Q0 date=$(date)"; } > $A 2>&1

/system/bin/su -c id >> $A 2>&1
echo "Q1_control rc=$?" >> $A 2>&1

/system/bin/sh -c '/system/bin/su "$@"' z6run -c id >> $A 2>&1
echo "Q2_argv0_z6run rc=$?" >> $A 2>&1

/system/bin/sh -c '/system/bin/su "$@"' sh -c id >> $A 2>&1
echo "Q3_argv0_sh rc=$?" >> $A 2>&1

/system/bin/sh -c '/system/bin/su "$@"' z6su -c id >> $A 2>&1
echo "Q4_argv0_z6su_(negative control, should fail) rc=$?" >> $A 2>&1

/data/data/com.termux/files/usr/bin/su -c id >> $A 2>&1
echo "Q5_via_su_named_forwarder(should fail while it execs directly) rc=$?" >> $A 2>&1
echo "Q6 END date=$(date)" >> $A 2>&1
