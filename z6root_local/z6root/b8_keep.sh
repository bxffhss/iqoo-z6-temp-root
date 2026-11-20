#!/system/bin/sh
# b8_keep.sh —— 常驻补装：只盯官方 Manager 的 **pid 变化**，一变就补装驱动 fd。
#   为什么需要：fd 只属于"那一个进程"（`/proc/ksu_install_fd` 走 task_work_add），
#     App 被系统回收/被划掉后新进程没有 fd ⇒ 首页回退「不支持」。
#   为什么不学 FDKA：上一发实测 FDKA 每 5 秒往**随机瞬时子进程**种一次，结果 @sushd 通道 60s 内就死、
#     insmod 后 ~225s PMIC 看门狗硬复位。这里只在 **pid 变了** 那一下写一次，平时纯睡。
#   kill switch：删 /data/local/tmp/b8_keep，循环自己退出。
MGR=me.weishu.kernelsu
SW=/data/local/tmp/b8_keep
LOG=/data/local/tmp/b8_keep.log
if [ "$1" != "RUN" ]; then
  # ★去重（22:58 一手：同一窗口里被派两次 ⇒ 出现两个 root 实例，互相独立地往触发口写）：
  #   先把已有实例收掉，再起新的。只认 cmdline 里带 `b8_keep.sh RUN` 的 pid。
  for _p in $(ps -A -o PID,ARGS 2>/dev/null | grep -a 'b8_keep.sh RUN' | grep -av grep | awk '{print $1}'); do
    kill "$_p" 2>/dev/null
  done
  : > "$LOG"
  echo "START $(date +%T) up=$(cut -d' ' -f1 /proc/uptime)" >> "$LOG"
  setsid /system/bin/sh "$0" RUN >/dev/null 2>&1 &
  exit 0
fi
LP=""
while [ -e "$SW" ]; do
  P=$(pidof "$MGR" 2>/dev/null | cut -d' ' -f1)
  case "$P" in ''|*[!0-9]*) P="" ;; esac
  if [ -n "$P" ] && [ "$P" != "$LP" ]; then
    if echo "$P" > /proc/ksu_install_fd 2>/dev/null; then
      echo "INJ pid=$P t=$(date +%T) up=$(cut -d' ' -f1 /proc/uptime)" >> "$LOG"
    else
      echo "INJFAIL pid=$P t=$(date +%T)" >> "$LOG"
    fi
    LP="$P"
  fi
  [ -z "$P" ] && LP=""
  sleep 0.2
done
echo "STOP $(date +%T)" >> "$LOG"
