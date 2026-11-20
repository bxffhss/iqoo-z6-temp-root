#!/system/bin/sh
# z6_light.sh — 设备侧轻量总控：不装模块、不踢框架，只做「shd(idle=0)+主动抢装管理器+维持件」
#   用途：① z6_on.sh --no-modules 的内核侧；② z6_after.sh 软重启后恢复用。
#   由 root 腿(@sushd)派单运行。产出：root + su + 管理器「工作中[越狱模式]」，全程不重启 framework ⇒ 最稳。
LOG=/data/local/tmp/z6_light.out
exec >>"$LOG" 2>&1
log(){ echo "[$(date +%H:%M:%S)] $*"; }
MGR=me.weishu.kernelsu
SHD=/data/local/tmp/shd
SHD_PORT=31339
SETSID=/system/bin/setsid

log "===== Z6_LIGHT START pid=$$ uid=$(id -u) boot_id=$(cat /proc/sys/kernel/random/boot_id) ====="
log "mod=$(grep -c kernelsu /proc/modules) enf=$(cat /sys/fs/selinux/enforce 2>/dev/null)"

# ---------- cgroup 加固自身（脱离 /apps/*） ----------
mkdir -p /sys/fs/cgroup/z6stage 2>/dev/null
echo $$ > /sys/fs/cgroup/z6stage/cgroup.procs 2>/dev/null
echo -1000 > /proc/self/oom_score_adj 2>/dev/null

# ---------- 1) shd 根代理（idle=0 永不自退；setsid 脱离） ----------
for p in $(pidof shd 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 1
if [ -x "$SHD" ]; then
  ( cd /data/local/tmp && "$SETSID" nohup "$SHD" "$SHD_PORT" 0 </dev/null >>/data/local/tmp/shd.log 2>&1 & ) 2>/dev/null
  sleep 2
  for p in $(pidof shd 2>/dev/null); do
    echo "$p" > /sys/fs/cgroup/z6stage/cgroup.procs 2>/dev/null
    echo -1000 > /proc/$p/oom_score_adj 2>/dev/null
  done
  log "SHD=[$(pidof shd)] cgroup=[$(for p in $(pidof shd); do cat /proc/$p/cgroup 2>/dev/null|tail -1; done|tr '\n' ' ')]"
else
  log "SHD_MISS $SHD 不存在 ⇒ su 不可用"
fi

# ---------- 2) 主动抢装管理器 fd（b8_mgr 逻辑：force-stop→0.2s 抢装循环→am start） ----------
timeout 8 am force-stop "$MGR" >/dev/null 2>&1
sleep 1
(
  i=0; LP=""
  while [ "$i" -lt 80 ]; do
    i=$((i+1))
    P=$(pidof "$MGR" 2>/dev/null | cut -d' ' -f1)
    case "$P" in ''|*[!0-9]*) P="" ;; esac
    if [ -n "$P" ] && [ "$P" != "$LP" ]; then
      echo "$P" > /proc/ksu_install_fd 2>/dev/null && log "MGR 抢装 pid=$P 第 $i 轮"
      LP="$P"
    fi
    sleep 0.2
  done
) &
sleep 0.3
timeout 12 am start -n "$MGR/.ui.MainActivity" >/dev/null 2>&1
sleep 8
log "MGR=[$(pidof $MGR)] (抢装完，首页应=工作中[越狱模式])"

# ---------- 3) 维持件 b8_keep（管理器被系统重回收/重开后自动重抢装） ----------
if [ -f /data/local/tmp/b8_keep.sh ]; then
  touch /data/local/tmp/b8_keep
  chmod 755 /data/local/tmp/b8_keep.sh
  /system/bin/sh /data/local/tmp/b8_keep.sh >/dev/null 2>&1 &
  sleep 1
  for p in $(ps -A -o PID,ARGS 2>/dev/null | grep -a 'b8_keep.sh RUN' | grep -av grep | awk '{print $1}'); do
    echo "$p" > /sys/fs/cgroup/z6stage/cgroup.procs 2>/dev/null
    echo -1000 > /proc/$p/oom_score_adj 2>/dev/null
  done
  log "KEEPER 维持件已起（删 /data/local/tmp/b8_keep 即停）"
else
  log "KEEPER_MISS b8_keep.sh 不在 ⇒ 不做维持"
fi

log "===== Z6_LIGHT DONE ====="
echo "===== DONE ====="
