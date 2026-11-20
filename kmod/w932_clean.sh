#!/system/bin/sh
# w932_clean.sh — 收掉本会话(第 60 发那天 18:1x–18:4x)在设备上铺的腿件与产物，**自删**。
# 只动我自己今天造的名字；★不碰 /data/local/tmp/kd(改道落点，窗口还要用)、不碰 pbin/(su 层)、
# 不碰 10-02 那次 boot 留下的 w91_*/w94_*(不是我这一轮造的，按"陌生件先不动"处理)。
O=/data/local/tmp/w932.out
{
  echo "C0 date=$(date) up=$(cut -d' ' -f1 /proc/uptime) id=[$(id)]"
  rm -f /data/local/tmp/w914.out /data/local/tmp/w915.out /data/local/tmp/w931_appleg.sh
  echo "C1 剩余 w9* 条目数=$(ls -1 /data/local/tmp | grep -ac '^w9')"
  ls -1 /data/local/tmp | grep -a '^w9'
  echo "C2 保留核对 kd=$(ls -l /data/local/tmp/kd 2>&1 | cut -d' ' -f5) pbin_su=$(ls -l /data/local/tmp/pbin/su 2>&1 | cut -d' ' -f5)"
  echo "C3 enf=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -c '^kernelsu ' /proc/modules 2>&1)"
  rm -f /data/local/tmp/w932_clean.sh
  echo "C4 自删后 w932_clean.sh 还在吗=$(ls /data/local/tmp/w932_clean.sh 2>&1)"
} > $O 2>&1
chmod 666 $O 2>&1
