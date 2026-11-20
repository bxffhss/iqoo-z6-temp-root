#!/system/bin/sh
# w930_revert.sh — 把交付槽恢复成出货字节（sustatic v3 = f7a441d2），并现场复证。
# 回退源＝/data/local/tmp/kd：它本来就是同一份 v3 的副本（w925 C1 两端 md5 相等），且是改道落点，本来就要留。
O=/data/local/tmp/w930.out
{
  echo "T0 date=$(date) up=$(cut -d' ' -f1 /proc/uptime) id=[$(id)]"
  echo "T1 恢复前 slot=$(md5sum /product/bin/su 2>&1)"
  echo "T1b 回退源=$(md5sum /data/local/tmp/kd 2>&1)"
  cp /data/local/tmp/kd /data/local/tmp/pbin/su.v3bak 2>&1
  chmod 755 /data/local/tmp/pbin/su.v3bak 2>&1
  chown root:root /data/local/tmp/pbin/su.v3bak 2>&1
  mv /data/local/tmp/pbin/su.v3bak /data/local/tmp/pbin/su 2>&1
  echo "T2 mv rc=$?"
  echo "T3 恢复后 slot=$(md5sum /product/bin/su 2>&1)"
  echo "T3 期望=f7a441d2a7aa0445bc9c7139df4838a3"
  ls -l /product/bin/su 2>&1
  echo '-- T4 功能性复证不在这条腿里做：root 壳里 uid 已经是 0，测不出 app 域能不能用'
  echo '    改由 run-as com.termux 那条腿(w931)复证'
} > $O 2>&1
chmod 666 $O 2>&1
