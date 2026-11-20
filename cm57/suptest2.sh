#!/system/bin/sh
# suptest2.sh — 由 uid2000 验 SIGPIPE 修复 + 监督循环能否把 daemon 拉起来
L=/data/local/tmp/sud.log
rm -f $L
{
  echo "=== suptest2 uid=$(id -u) ==="
  setsid nohup sh -c 'while :; do /data/local/tmp/sud --daemon; echo "[sup] 重来"; sleep 2; done' </dev/null >>$L 2>&1 &
  SUP=$!
  sleep 1
  echo "--- 第一次: 消费者只取一行(shim 提前退出 => 旧版在这里被 SIGPIPE 打死) ---"
  /data/local/tmp/sud -c 'for i in 1 2 3 4 5; do echo out-$i; sleep 1; done' | head -1
  sleep 4
  echo "--- daemon 还在吗 ---"
  ps -A -o PID,UID,NAME | grep -w sud
  echo "--- 再走一次 ---"
  /data/local/tmp/sud -c 'echo ALIVE-AGAIN'
  echo "rc=$?"
  echo "--- supervisor 的重启计数 ---"
  grep -c '重来' $L
  cat $L
  kill $SUP 2>/dev/null
  pkill -f 'sud --daemon' 2>/dev/null
  echo "=== 结束 ==="
} 2>&1
