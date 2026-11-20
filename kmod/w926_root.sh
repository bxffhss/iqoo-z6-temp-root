#!/system/bin/sh
# w926_root.sh — 第 60 发 Permissive 段的 root-only 读数汇总（L5/L6）。经
#   run-as com.termux + env /system/bin/su < 本文件 执行（uid 10667→0，域 shell，全程免打字）。
# 为什么这些腿必须在翻执法之前跑：/proc/ksu_*、dmesg、/data/adb 在执法态下对 shell/run-as 都是
# EACCES（§6.440~442 的那条铁律）。
O=/data/local/tmp/w926.out
{
  echo "R0 date=$(date) up=$(cut -d' ' -f1 /proc/uptime) id=[$(id)]"
  echo "R1 enf=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -c '^kernelsu ' /proc/modules 2>&1)"
  echo "R2 bootreason=[$(getprop ro.boot.bootreason 2>&1)] hist=[$(getprop persist.sys.boot.reason.history 2>&1)]"
  echo "-- R3 /proc/ksu_* 节点"
  for n in cfiscan fixcfi fixuts openprobe slots install_fd; do
    echo "R3.$n exists=$(/system/bin/ls -l /proc/ksu_$n 2>&1 | /system/bin/awk '{print $1,$3,$4,$5}')"
  done
  echo "-- R4 ksu_slots 头 40 行"
  head -40 /proc/ksu_slots 2>&1
  echo "-- R5 谁在监听 @suwshd / @suwksu（#202 那一格的现场）"
  grep -a -E "suwshd|suwksu|sushd" /proc/net/unix 2>&1
  echo "-- R6 在跑的 root agent / 维持件"
  ps -A -o PID,USER,NAME 2>&1 | grep -a -E "kd|ksud|shd|sustatic|keeper|w4[0-9][0-9]" | grep -a -v grep
  echo "-- R7 /data/adb 与 /data/local/tmp 现场"
  ls -laR /data/adb 2>&1 | head -40
  ls -l /data/local/tmp 2>&1 | head -40
  echo "-- R8 挂载形状（/product/bin 那条 bind 还在不在）"
  grep -a -E " /product /system /odm " /proc/self/mountinfo 2>&1 | head -20
  echo "-- R9 #204 复读：目标进程现在有没有驱动 fd"
  for p in $(pidof me.bartuzsufix.test 2>/dev/null) $(pidof com.termux 2>/dev/null) $(pidof org.meowcat.edxposed.manager 2>/dev/null); do
    echo "R9 pid=$p comm=$(cat /proc/$p/comm 2>&1) fd_ksu=$(ls -l /proc/$p/fd 2>/dev/null | grep -ac ksu_driver)"
  done
  echo "-- R10 上一发装 fd 的落点读数（谁被装过）"
  grep -a -E "KSUFDINST|FDINST" /proc/kmsg 2>/dev/null | tail -5
  dmesg 2>/dev/null | grep -a -E "KSUFDINST" | tail -8
  echo "-- R11 整环快照搬去可读位置"
  dmesg > /data/local/tmp/w926_ring.txt 2>&1
  chmod 666 /data/local/tmp/w926_ring.txt 2>&1
  echo "R11 ring_bytes=$(ls -l /data/local/tmp/w926_ring.txt 2>/dev/null | awk '{print $5}')"
  echo "RZ_END date=$(date) up=$(cut -d' ' -f1 /proc/uptime)"
} > $O 2>&1
chmod 666 $O 2>&1
