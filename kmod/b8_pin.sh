#!/system/bin/sh
# b8_pin.sh —— 把官方 Manager 的 oom_score_adj 调到 -1000，防止被 LMK 回收。
#   为什么要：fd 只属于"那一个进程"，进程一被回收就只能靠重组竞态去抢，抢输了就回「不支持」。
#   注意：-1000 只挡 LMK，挡不住"用户从最近任务里划掉"（那是 force-stop）。
P=$(pidof me.weishu.kernelsu 2>/dev/null | cut -d' ' -f1)
OUT=/data/local/tmp/b8_pin.out
{
  echo "PIN t=$(date +%T) pid=[$P]"
  if [ -n "$P" ]; then
    for t in /proc/$P/task/*; do
      echo -1000 > "$t/oom_score_adj" 2>/dev/null
    done
    echo "read_back=$(cat /proc/$P/oom_score_adj 2>&1)"
  else
    echo "没拿到 pid ⇒ 没钉"
  fi
  echo "DONE"
} > "$OUT" 2>&1
