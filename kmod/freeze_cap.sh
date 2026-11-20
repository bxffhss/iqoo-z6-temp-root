#!/system/bin/sh
# freeze_cap.sh —— 管理器"卡死"当口的取证（必须由 root 腿派单：读 /proc/<pid>/fd 与 /data/anr 都要 root）。
#   要回答的问题只有一个：主线程当时卡在**等 su/ksud**，还是卡在别处（渲染/无障碍/锁）。
P=$(pidof me.weishu.kernelsu 2>/dev/null | cut -d' ' -f1)
OUT=/data/local/tmp/freeze_cap.out
{
  echo "=== freeze capture $(date +%H:%M:%S) pid=[$P] ==="
  if [ -z "$P" ]; then echo "没拿到 pid"; echo "DONE"; exit 0; fi
  echo "--- fd 数（看有没有涨/泄漏） ---"; ls /proc/$P/fd 2>/dev/null | wc -l
  echo "--- 线程数 ---"; ls /proc/$P/task 2>/dev/null | wc -l
  echo "--- oom_score_adj ---"; cat /proc/$P/oom_score_adj 2>/dev/null
  echo "--- 各线程状态统计（R=运行 D=不可中断 S=睡） ---"
  for t in /proc/$P/task/*; do
    st=$(cut -d' ' -f3 "$t/stat" 2>/dev/null)
    cm=$(cat "$t/comm" 2>/dev/null)
    echo "$st $cm"
  done | sort | uniq -c | sort -rn | head -12
  echo "--- 主线程 wchan（卡在哪个内核等待点） ---"
  cat /proc/$P/task/$P/wchan 2>/dev/null; echo
  echo "--- 主线程 stack 关键字扫描（su/ksud/execve/wait） ---"
  cat /proc/$P/task/$P/stack 2>/dev/null | head -8
  echo "--- kill -3 抓 Java 栈 ---"
  kill -3 "$P" 2>/dev/null; sleep 4
  N=$(ls -t /data/anr/ 2>/dev/null | head -1)
  echo "最新 ANR 件: [$N]"
  if [ -n "$N" ]; then
    cp "/data/anr/$N" /data/local/tmp/anr_latest.txt 2>/dev/null
    echo "已复制 -> /data/local/tmp/anr_latest.txt 字节=$(wc -c < /data/local/tmp/anr_latest.txt 2>/dev/null)"
    echo "--- 主线程片段（前 40 行） ---"
    sed -n "/\"main\"/,/^$/p" /data/local/tmp/anr_latest.txt 2>/dev/null | head -40
  fi
  echo "--- 含 su/KsuCli 的栈行 ---"
  grep -a -m 20 -e KsuCli -e "su " -e "ProcessBuilder" -e "java.lang.Process" /data/local/tmp/anr_latest.txt 2>/dev/null | head -20
  echo "DONE"
} > "$OUT" 2>&1
