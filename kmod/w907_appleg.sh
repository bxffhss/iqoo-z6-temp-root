#!/system/bin/sh
# w907_appleg.sh — verify #207: bare `su` in this host must now reach the working 改道 chain.
HA=/data/data/com.termux/files/home
A=$HA/w907_app.out
{
  echo "T0 date=$(date)"
  echo "T1 path_su=$(command -v su 2>&1)"
  echo "T2 head_of_that_file=$(head -c 200 $(command -v su) 2>&1 | tr '\n' '|')"
  echo "T3 md5_of_that_file=$(md5sum $(command -v su) 2>&1)"
} > $A 2>&1
su -c id >> $A 2>&1
echo "T4 rc_bare_su_dashc=$?" >> $A 2>&1
printf 'id\nexit\n' | su >> $A 2>&1
echo "T5 rc_bare_su_piped=$?" >> $A 2>&1
echo "T6 bare_su_v=$(su -v 2>&1 | head -1)" >> $A 2>&1
echo "T7 id_after=$(id)" >> $A 2>&1
echo "T8 END date=$(date)" >> $A 2>&1
