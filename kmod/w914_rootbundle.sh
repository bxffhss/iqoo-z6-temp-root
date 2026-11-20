#!/system/bin/sh
# w914_rootbundle.sh — 本窗 Permissive 段的一次性 root 腿包：授权 Termux（L2 的前置）＋ L3(#204 装 fd)。
# 跑法：由 suw 的 @sushd 派发（root）。★显式给 PATH——root 壳的 PATH 里没有 getenforce 之类。
PATH=/system/bin:/vendor/bin:/system/xbin:/sbin:$PATH
O=/data/local/tmp/w914.out
CTL=/data/local/tmp/ksuctl88
{
  echo "B0 date=$(date) up=$(cut -d' ' -f1 /proc/uptime) enf_raw=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -ac kernelsu /proc/modules) uid=$(id -u)"
  T=$(/system/bin/pidof com.termux 2>/dev/null | tr ' ' '\n' | head -1)
  echo "B1 termux_pid=[$T] ctl=$(ls -l $CTL 2>&1 | tail -1)"
  echo "-- 授权 Termux：写一条 profile，域显式 u:r:shell:s0（＝今天 13:2x 实测的那个形状，别用内核默认模板）"
  $CTL setprof 10667 com.termux u:r:shell:s0 2>&1
  echo "-- 回读 UID_GRANTED_ROOT"
  $CTL granted 10667 2>&1
  echo "-- 名单/活表现值"
  $CTL allowlist 2>&1 | head -10
  echo "-- L3(#204)：给一个在跑的 app 装驱动 fd"
  if [ -n "$T" ] && [ -e /proc/ksu_install_fd ]; then
    echo "$T" > /proc/ksu_install_fd
    echo "   echo pid > /proc/ksu_install_fd rc=$?"
    sleep 1
    echo "   该进程 fd 里 ksu 条数=$(ls -l /proc/$T/fd 2>/dev/null | grep -ac ksu)"
    ls -l /proc/$T/fd 2>/dev/null | grep -a ksu | head -3
    FD=$(/system/bin/ls /proc/$T/fd 2>/dev/null | while read -r x; do readlink /proc/$T/fd/$x 2>/dev/null | grep -aq ksu && echo $x; done | head -1)
    echo "   那个 fd=[$FD] 的 fdinfo flags: $(grep -a '^flags' /proc/$T/fdinfo/$FD 2>&1)  ⇒ 含 O_CLOEXEC 位(0x80000)则子进程 exec 后看不见"
    echo "-- B9 END up=$(cut -d' ' -f1 /proc/uptime)"
  else
    echo "   未测：pid 取不到或触发口不在（不是判负）"
  fi
} > "$O" 2>&1
