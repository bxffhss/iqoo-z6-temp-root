#!/system/bin/sh
# race_rearm.sh —— 窗口内**重臂**官方 Manager 的 fd 抢装（把 stage 里那 30s 看门狗手工再跑一次）。
# 机制：ksu_one_stage.sh:705  `echo "$MPID" > /proc/ksu_install_fd` 即把 KSU 驱动 fd 装进该进程；
#   官方首页「支持/不支持」是**启动时一次性分支**(stage 注释 673-674：杀掉重起并被抢装 ⇒ 立刻变「工作中 [越狱模式]」)。
# 为什么需要：go.sh 第 5 步(SU_BIND) 绑 su 在判据⑥(看门狗窗口)之后 ⇒ 被抢装的实例没 su、「获取 Root 失败」；
#   补绑 su 后若直接重启 app 又会丢掉 fd(掉回「不支持」GKI 闸)。⇒ 现在 su 已绑，把 fd 抢装重臂一次，两者同时到位。
# 用法（root 侧跑，经 @sushd）：本件自后台化；再由 PC 侧 force-stop + am start 官方 app 配合。
MGR=me.weishu.kernelsu
LOG=/data/local/tmp/race_rearm.out
if [ "$1" != "RUN" ]; then
  : > "$LOG"
  echo "launcher uid=$(id -u) up=$(cut -d' ' -f1 /proc/uptime) trig=$(ls -l /proc/ksu_install_fd 2>&1)" >> "$LOG"
  setsid /system/bin/sh "$0" RUN >/dev/null 2>&1 &
  echo "LAUNCHED bg pid=$! up=$(cut -d' ' -f1 /proc/uptime)" >> "$LOG"
  exit 0
fi
echo "watchdog start up=$(cut -d' ' -f1 /proc/uptime)" >> "$LOG"
i=1
while [ "$i" -le 75 ]; do
  P=$(pidof "$MGR" 2>/dev/null | awk '{print $1}')
  if [ -n "$P" ]; then
    if echo "$P" > /proc/ksu_install_fd 2>/dev/null; then
      echo "WRITE ok pid=$P round=$i up=$(cut -d' ' -f1 /proc/uptime)" >> "$LOG"
    else
      echo "WRITE FAIL pid=$P round=$i" >> "$LOG"
    fi
  fi
  sleep 0.4
  i=$((i+1))
done
echo "watchdog done up=$(cut -d' ' -f1 /proc/uptime)" >> "$LOG"
