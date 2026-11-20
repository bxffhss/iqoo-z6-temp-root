#!/system/bin/sh
# b8_mgr.sh —— 由 root 腿派单：按"fd 与 su 都在出生前就位"的顺序重起官方 Manager。
#   为什么现在能做：B8 的名单主条目仍是 suw(10342) ⇒ @sushd 这条 root 腿活着；
#   而 stage 那次 am start 早于 go.sh 第 5 步的 bind ⇒ 官方 App 把「获取 Root 失败」缓存进了进程。
MGR=me.weishu.kernelsu
LOG=/data/local/tmp/b8_mgr.out
{
  echo "=== 重起官方 Manager $(date +%H:%M:%S) ==="
  echo "前置：su=$(ls -l /product/bin/su 2>&1 | tail -1)"
  am force-stop $MGR >/dev/null 2>&1
  sleep 1
  (
    i=0; LP=""
    while [ "$i" -lt 80 ]; do
      i=$((i+1))
      P=$(pidof $MGR 2>/dev/null | cut -d' ' -f1)
      case "$P" in ''|*[!0-9]*) P="" ;; esac
      if [ -n "$P" ] && [ "$P" != "$LP" ]; then
        if echo "$P" > /proc/ksu_install_fd 2>/dev/null; then
          echo "抢装 pid=$P 第 $i 轮"
        else
          echo "写口失败 pid=$P 第 $i 轮"
        fi
        LP="$P"
      fi
      sleep 0.2
    done
  ) &
  sleep 0.3
  am start -n $MGR/.ui.MainActivity >/dev/null 2>&1
  sleep 8
  echo "MGR_PID=$(pidof $MGR)"
  echo "=== DONE"
} >> "$LOG" 2>&1
