#!/system/bin/sh
# z6_stage4.sh — 阶段 4 设备侧总控（root、完全脱离、框架重建期间自持）
# 设计要点：
#   ① 迁出 /apps/* cgroup（framework 重建时 ActivityManager/lmkd 按 cgroup 清理，本发 daemon 全死在这）
#   ② 全程写 /data/local/tmp/z6_stage4.log (0666)，主机侧只轮询这一个文件
#   ③ 不依赖 adb、不依赖 @sushd 腿；所有动作自己跑完
#   ④ 两轮：轮1 = 阶段3注入+阶段4点火合并成一次踢；失败则轮2 再踢一次（Z5 全套本来就是两次框架重启）
LOG=/data/local/tmp/z6_stage4.log
: > "$LOG" 2>/dev/null; chmod 666 "$LOG"
exec >>"$LOG" 2>&1

M=/data/adb/modules
ZN=$M/zygisksu/bin/zygiskd
LP=$M/zygisk_lsposed
ZNZIP='/sdcard/Download/必备模块/Zygisk-Next-1.5.2-864-a4a72ce-relea.zip'
SETSID=/system/bin/setsid
RUNCON=/system/bin/runcon
APP_PROCESS=/system/bin/app_process
TIMEOUT=/system/bin/timeout
UNZIP=/system/bin/unzip
PROBE=/data/local/tmp/probe2.jar
MON=/data/adb/lspd/monitor
SHD=/data/local/tmp/shd
SHD_PORT=31339
MGR=me.weishu.kernelsu

log(){ echo "[$(date +%H:%M:%S)] $*"; }

log "===== STAGE4 START pid=$$ uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null) ====="

# ---------- ① cgroup 加固：脱离 /apps/* 子树 ----------
mkdir -p /sys/fs/cgroup/z6stage 2>/dev/null
echo $$ > /sys/fs/cgroup/z6stage/cgroup.procs 2>/dev/null && log "CG_V2_OK -> /sys/fs/cgroup/z6stage" || log "CG_V2_FAIL (non-fatal)"
echo $$ > /dev/memcg/cgroup.procs 2>/dev/null && log "CG_MEM_OK" || log "CG_MEM_FAIL (non-fatal)"
echo -1000 > /proc/self/oom_score_adj 2>/dev/null
log "AFTER_HARDEN cgroup2=[$(cat /proc/self/cgroup 2>/dev/null | tail -1)] oom=$(cat /proc/self/oom_score_adj 2>/dev/null)"

# ---------- 前置读数 ----------
log "boot_id=$(cat /proc/sys/kernel/random/boot_id) up=$(cut -d' ' -f1 /proc/uptime)"
log "mod=$(grep -c kernelsu /proc/modules) enf=$(cat /sys/fs/selinux/enforce) boot_completed=$(getprop sys.boot_completed)"
log "zygote64=$(pidof zygote64) start_ticks=$(awk '{print $22}' /proc/$(pidof zygote64)/stat 2>/dev/null)"
log "probe2=$(ls -l $PROBE 2>&1 | awk '{print $5}') ZN=$(ls -l $ZN 2>&1 | awk '{print $5}')"
log "lspd_daemon=$(ls -l $LP/daemon 2>&1 | awk '{print $5}')"

# ---------- 工具函数 ----------
# ZN daemon 起来（若已跑则跳过）
# ★★11-15 一发的教训：必须按 w210 验证过的形态启动，且**启动成功后才允许踢框架**。
#   w210 成功形态 = cd 到模块目录 + 清 .injecting/.abort_msg + nohup setsid + 从 zip 恢复 module.prop。
#   本发首版直接 ( setsid zygiskd daemon & ) 且 cwd 不对 ⇒ RC=1 无输出，却照样踢了框架 ⇒ 白白重建一次。
start_zn(){
  if [ -n "$(pidof zn-daemon 2>/dev/null)" ]; then log "ZN already running: $(pidof zn-daemon)"; return 0; fi
  # 每次启动前从 zip 恢复 module.prop（daemon 的 write prop 会改内容，verify1 会拒）
  "$UNZIP" -o "$ZNZIP" 'module.prop' -d "$M/zygisksu" >/dev/null 2>&1
  rm -f /data/adb/zygisksu/.abort_msg /data/adb/zygisksu/.injecting
  log "ZN pre-launch: locks cleared, module.prop hash=$(sha256sum "$M/zygisksu/module.prop" | awk '{print $1}')"
  # ★关键：cwd 必须是模块目录（post-fs-data.sh 第一件事就是 cd "$MODDIR"）
  ( cd "$M/zygisksu" && nohup "$SETSID" "$ZN" daemon >/data/local/tmp/z6_zn.log 2>&1 </dev/null & ) 2>/dev/null
  sleep 6
  log "ZN after start: [$(pidof zn-daemon)] status=$("$TIMEOUT" 8 "$ZN" status 2>&1 | grep -aE 'version:|inject_state|zygote_states|err:' | tr '\n' ' ')"
  log "ZN zn_log=[$(head -5 /data/local/tmp/z6_zn.log 2>&1 | tr '\n' ' ')] abort=[$(cat /data/adb/zygisksu/.abort_msg 2>&1)]"
}

# ★★gate：ZN 注入器必须真的就位，才允许踢框架
# ★第三发新增：还要 root_status:✅KernelSU。第三发实测 inject_state:1 但 root_status:❌None，
#   logcat 报 GetRootImpl permission denied ⇒ 框架重启了但注入没发生。
zn_gate(){
  S=$("$TIMEOUT" 8 "$ZN" status 2>&1)
  echo "$S" | grep -aq 'inject_state:1' || return 1
  [ -n "$(pidof zn-daemon 2>/dev/null)" ] || return 1
  echo "$S" | grep -aq 'root_status:✅' || {
    log "ZN_GATE_FAIL root_status not ✅: [$(echo "$S" | grep -a 'root_status')]"; return 1; }
  log "ZN_GATE_OK status=[$(echo "$S" | grep -aE 'inject_state|zygote_states|root_status|modules' | tr '\n' ' ')]"
  return 0
}

# lspd 起来（必须 system_server 域；双 fork 完全脱离）
start_lspd(){
  if [ -n "$(pidof lspd 2>/dev/null)" ]; then log "lspd already running: $(pidof lspd)"; return 0; fi
  rm -f /data/local/tmp/daemon.apk /data/local/tmp/manager.apk
  ( "$SETSID" "$RUNCON" u:r:system_server:s0 sh -c "cd $LP && exec ./daemon --force" >/data/local/tmp/z6_lspd.log 2>&1 </dev/null & ) 2>/dev/null
  sleep 5
  log "lspd after start: [$(pidof lspd)] monitor=[$(cat $MON 2>/dev/null)]"
}

# ★Goal1：让 suw 根代理 shd 扛过踢框架（su/root 授权与 LSPosed 同窗可用）
#   原理：shd 自己用 magic-reboot 拿 KSU fd（ksu_fd_get，root 域可独立拿、不依赖 app 树）；
#   把它 setsid 脱离(父=init) + 迁进 z6stage cgroup ⇒ 踢 zygote 不波及它，踢后仍听 @suwshd。
#   ★必须在踢框架之前起：先清掉 app 树里那份(踢后必死、还占 @suwshd)，再起脱离版。
start_shd_detached(){
  for p in $(pidof shd 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  sleep 1
  [ -x "$SHD" ] || { log "SHD_MISS $SHD 不存在 ⇒ 跳过"; return 1; }
  : > /data/local/tmp/shd.log 2>/dev/null; chmod 666 /data/local/tmp/shd.log 2>/dev/null
  ( cd /data/local/tmp && "$SETSID" nohup "$SHD" "$SHD_PORT" 0 </dev/null >>/data/local/tmp/shd.log 2>&1 & ) 2>/dev/null
  sleep 2
  local pp=""
  for p in $(pidof shd 2>/dev/null); do
    echo "$p" > /sys/fs/cgroup/z6stage/cgroup.procs 2>/dev/null
    echo -1000 > /proc/$p/oom_score_adj 2>/dev/null
    pp="$pp $p"
  done
  log "SHD detached=[$pp] cgroup=[$(for p in $pp; do cat /proc/$p/cgroup 2>/dev/null | tail -1; done | tr '\n' ' ')] log=[$(tail -1 /data/local/tmp/shd.log 2>/dev/null)]"
  [ -n "$pp" ]
}

# ★Goal2：把 KSU 驱动 fd 装进官方管理器(me.weishu.kernelsu) ⇒ 它扫 /proc/self/fd 找到 [ksu_driver]
#   ⇒ 官方界面显示"支持"。机制＝ko 的 /proc/ksu_install_fd(0600)：root echo <pid> 即装进该进程
#   （dev_syms.c §6.81，无需重建 ko）。踢框架会杀掉管理器，所以放在流程末尾、框架稳定后再装。
install_mgr_fd(){
  # ★B8 抢装法（一手 §6.407）：manager 只在启动那刻查一次 fd；fd 晚到它不重查 ⇒ 一直"不支持"。
  #   正解＝force-stop 后，后台 0.2s 抢装循环盯新 pid 写 /proc/ksu_install_fd，再 am start ⇒ 启动即见 fd ⇒ 工作中[越狱模式]
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
  log "MGR_FD mgr_pid=[$(pidof $MGR)] (抢装完；首页应=工作中[越狱模式])"
}

# ★越狱模式稳定件(B8 b8_keep)：管理器被系统回收/重开⇒新 pid 没 fd⇒回退"不支持"。
#   维持件盯 pid，一变就重抢装 ⇒ 首页始终「工作中[越狱模式]」。开关＝/data/local/tmp/b8_keep（删即停）。
start_keeper(){
  [ -f /data/local/tmp/b8_keep.sh ] || { log "KEEPER_MISS b8_keep.sh 不在 ⇒ 跳过维持件"; return 1; }
  touch /data/local/tmp/b8_keep; chmod 755 /data/local/tmp/b8_keep.sh
  /system/bin/sh /data/local/tmp/b8_keep.sh >/dev/null 2>&1 &
  sleep 1
  local kp=""
  for p in $(ps -A -o PID,ARGS 2>/dev/null | grep -a 'b8_keep.sh RUN' | grep -av grep | awk '{print $1}'); do
    echo "$p" > /sys/fs/cgroup/z6stage/cgroup.procs 2>/dev/null
    echo -1000 > /proc/$p/oom_score_adj 2>/dev/null
    kp="$kp $p"
  done
  log "KEEPER started=[$kp] (越狱模式将随管理器重启自动维持)"
}

# 打针：probe2 连 abstract socket 触发 lspd 抢注 serial
poke(){
  NAME=$(cat "$MON" 2>/dev/null)
  [ -z "$NAME" ] && { log "POKE_SKIP: monitor empty"; return 1; }
  # 先杀 PPID=1 的 lspd（Z5 guard.sh 语义：让 daemon 重抢）
  for p in $(pidof lspd 2>/dev/null); do
    pp=$(cut -d' ' -f4 /proc/$p/stat 2>/dev/null)
    [ "$pp" = "1" ] && kill -9 "$p" 2>/dev/null
  done
  sleep 1
  # ★加 timeout：Probe2 若在 socket 上卡住会拖死 guard 循环；它是发一笔读一笔就退的短命客户端
  "$TIMEOUT" 6 "$APP_PROCESS" -Djava.class.path="$PROBE" /system/bin Probe2 "$NAME" >/dev/null 2>&1
  log "POKE probe2 rc=$?"
  sleep 1
  S=$("$TIMEOUT" 8 "$RUNCON" u:r:shell:s0 service list 2>/dev/null | grep -a serial)
  log "POKE name=$NAME -> serial=[$S]"
}

# 读 serial（root 域看 service list 是 0 个服务，必须切 shell 域）
read_serial(){
  "$TIMEOUT" 8 "$RUNCON" u:r:shell:s0 service list 2>/dev/null | grep -a serial
}

# 踢框架
kick(){
  PSS=$(pidof system_server); P64=$(pidof zygote64); P32=$(pidof zygote)
  log "KICK target ss=$PSS z64=$P64 z32=$P32"
  kill -9 $PSS $P64 $P32 2>/dev/null
  echo "KICK rc=$?"
}

# 等 framework 回来（zygote 换 pid + boot_completed=1）
wait_framework(){
  OLD=$1; i=0
  while [ $i -lt 60 ]; do
    Z=$(pidof zygote64 2>/dev/null)
    BC=$(getprop sys.boot_completed 2>/dev/null)
    if [ -n "$Z" ] && [ "$Z" != "$OLD" ] && [ "$BC" = "1" ]; then
      log "FRAMEWORK_BACK after $((i*3))s: zygote64=$Z start=$(awk '{print $22}' /proc/$Z/stat 2>/dev/null) boot_completed=$BC"
      return 0
    fi
    i=$((i+1)); sleep 3
  done
  log "FRAMEWORK_WAIT_TIMEOUT (180s)"; return 1
}

# guard：窗口内每 1s 读 serial，不是 [] 就重打针
# ★用纯计数循环，不依赖设备 toybox date 是否支持 +%s
guard(){
  DUR=$1; i=0; n=0
  log "GUARD start dur=${DUR}s"
  while [ "$i" -lt "$DUR" ]; do
    [ -d "$LP" ] || { log "GUARD_BAIL LSPosed 模块目录消失 ⇒ 放弃 LSPosed(不空转)"; return 2; }
    S=$(read_serial)
    case "$S" in
      *"[]"*) n=$((n+1)); [ $((n % 15)) -eq 1 ] && log "GUARD ok($n) serial=[$S]" ;;
      *) log "GUARD re-arm(i=$i) serial=[$S]"; start_lspd; poke; n=0 ;;
    esac
    i=$((i+1))
    sleep 1
  done
  log "GUARD done final_serial=[$(read_serial)]"
}

# 验收
# ★★11-15 一发的教训：SUCCESS 不能只看 serial: []（那只是桥），
#   必须同时有 ZN 注入证据（module.prop 的 ✅zygote + inject_state:1）。
verify(){
  log "--- VERIFY ---"
  log "module.prop=[$(grep -a '^description=' $M/zygisksu/module.prop 2>/dev/null)]"
  log "serial=[$(read_serial)]"
  log "lspd=[$(pidof lspd)] zndaemon=[$(pidof zn-daemon)]"
  log "znctl=[$("$TIMEOUT" 8 "$ZN" status 2>&1 | grep -aE 'version:|inject_state|zygote_states|modules_with_issue' | tr '\n' ' ')]"
  log "zygote64_start=$(awk '{print $22}' /proc/$(pidof zygote64)/stat 2>/dev/null) boot_completed=$(getprop sys.boot_completed)"
}

# ★完整成功判据：桥 + ZN 注入 + 管理器已激活，三者齐才算数
full_success(){
  S=$(read_serial)
  case "$S" in *"[]"*) ;; *) log "FAIL_CRIT serial not bridged: [$S]"; return 1 ;; esac
  # ★模块目录可能被 KSU 清理删掉，但 lspd 已注入、serial 已桥接 ⇒ LSPosed 实际生效。有 module.prop 就查 ✅zygote，没有就看 lspd 活着。
  if [ -f "$M/zygisksu/module.prop" ]; then
    grep -a '^description=' "$M/zygisksu/module.prop" 2>/dev/null | grep -aq '✅zygote' || {
      log "FAIL_CRIT ZN 未写 ✅zygote（注入没发生）"; return 1; }
  elif [ -z "$(pidof lspd)" ]; then
    log "FAIL_CRIT 模块目录没了且 lspd 没活 ⇒ 无法认定 LSPosed"; return 1
  else
    log "NOTE module.prop 已没了但 lspd 活着+serial[] ⇒ 按 LSPosed 生效算"
  fi
  log "FULL_SUCCESS_CRITERIA_MET (桥 + LSPosed 生效)"
  return 0
}

# ================= 主流程 =================
ROUND=0
while [ "$ROUND" -lt 2 ]; do
  ROUND=$((ROUND+1))
  log "########## ROUND $ROUND ##########"

  start_zn
  # ★★gate：ZN 注入器没就位就绝不踢框架（本发首版在这里白费了一次重建）
  ZOK=0
  for t in 1 2 3; do
    if zn_gate; then ZOK=1; break; fi
    log "ZN_GATE_FAIL attempt=$t ⇒ 重试 start_zn（cwd/锁/启动形态）"
    start_zn
  done
  if [ "$ZOK" -ne 1 ]; then
    log "===== ABORT: ZN 注入器始终没起来，不踢框架（避免无意义的 framework 重建） ====="
    log "诊断: zn_log=[$(cat /data/local/tmp/z6_zn.log 2>&1 | tail -10 | tr '\n' ' ')]"
    log "诊断: abort=[$(cat /data/adb/zygisksu/.abort_msg 2>&1)] locks=[$(ls -a /data/adb/zygisksu 2>&1 | tr '\n' ' ')]"
    verify
    log "===== STAGE4 END (ZN gate failed) ====="
    exit 2
  fi

  start_lspd
  poke
  start_shd_detached

  OLDZ=$(pidof zygote64 2>/dev/null)
  kick
  log "KICK issued, waiting 4s before guard"
  sleep 4
  wait_framework "$OLDZ"

  # framework 重建后：zn-daemon / lspd 可能被清，补起
  log "POST-REBUILD procs: zndaemon=[$(pidof zn-daemon)] lspd=[$(pidof lspd)] shd=[$(pidof shd)]"
  # ★踢框架后 /data/adb/modules 可能被 KSU 清理 ⇒ lspd cd 失败起不来。缺了就重建一次（给 LSPosed 机会）
  if [ ! -d "$LP" ] || [ ! -f "$ZN" ]; then
    log "POST-REBUILD modules missing ⇒ 重建 w230"
    [ -f /data/local/tmp/w230_rebuild_all.sh ] && sh /data/local/tmp/w230_rebuild_all.sh >/dev/null 2>&1
    log "REBUILD lp=$([ -d "$LP" ] && echo ok || echo miss) zn=$([ -f "$ZN" ] && echo ok || echo miss)"
  fi
  start_zn
  start_lspd

  # 框架重建后的 150s 窗口内守 serial
  guard 150
  # ★Goal2：框架现在才彻底稳（踢后 11s 拉管理器会失败）；在 guard 后装 fd 才拉得起管理器
  install_mgr_fd
  start_keeper
  verify

  if full_success; then
    log "===== SUCCESS round=$ROUND (full criteria) ====="
    break
  else
    log "===== ROUND $ROUND NOT YET (full criteria failed) ====="
  fi
done

log "===== STAGE4 END (all rounds done) ====="
