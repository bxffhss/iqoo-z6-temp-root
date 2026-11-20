#!/system/bin/sh
# w915_root_fd.sh — L3(#204) 单独一条：给一个**在跑**的 app 装驱动 fd，并读回三件事
# （装上了没有 / 那个 fd 的 flags 里有没有 O_CLOEXEC / 名单里它自己是什么状态）。
PATH=/system/bin:/vendor/bin:/system/xbin:/sbin:$PATH
O=/data/local/tmp/w915.out
CTL=/data/local/tmp/ksuctl88
{
  echo "C0 date=$(date) up=$(cut -d' ' -f1 /proc/uptime) enf_raw=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -ac kernelsu /proc/modules) uid=$(id -u)"
  T=$(/system/bin/pidof com.termux 2>/dev/null | tr ' ' '\n' | head -1)
  echo "C1 termux_pid=[$T] 触发口=$(ls -l /proc/ksu_install_fd 2>&1 | tail -1)"
  [ -z "$T" ] && { echo "C2 未测：pidof 取不到(不是判负)"; exit 0; }
  echo "C3 装之前该进程 ksu fd 条数=$(ls -l /proc/$T/fd 2>/dev/null | grep -ac ksu)"
  echo "$T" > /proc/ksu_install_fd
  echo "C4 echo pid > /proc/ksu_install_fd rc=$?"
  sleep 1
  echo "C5 装之后 ksu fd 条数=$(ls -l /proc/$T/fd 2>/dev/null | grep -ac ksu)"
  ls -l /proc/$T/fd 2>/dev/null | grep -a ksu | head -3
  FD=""
  for x in $(ls /proc/$T/fd 2>/dev/null); do
    rl=$(readlink /proc/$T/fd/$x 2>/dev/null)
    case "$rl" in *ksu*) FD=$x ;; esac
  done
  echo "C6 那个 fd=[$FD] fdinfo: $(cat /proc/$T/fdinfo/$FD 2>&1 | tr '\n' ' ')"
  echo "C7 名单回读：$($CTL granted 10667 2>&1 | grep -a UID_GRANTED_ROOT | tail -1)"
  echo "C8 END up=$(cut -d' ' -f1 /proc/uptime)"
} > "$O" 2>&1
