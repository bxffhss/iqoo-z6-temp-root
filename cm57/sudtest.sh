#!/system/bin/sh
# sudtest.sh — 不需要 root: 只用 uid2000 验证 daemon<->shim 的 socket 通路对不对
L=/data/local/tmp/sudtest.log
rm -f $L
{
  echo "=== sudtest uid=$(id -u) ==="
  /data/local/tmp/sud --daemon </dev/null >>$L.daemon 2>&1 &
  DP=$!
  sleep 1
  echo "daemon pid=$DP alive=$(ls /proc/$DP >/dev/null 2>&1 && echo yes || echo no)"
  echo "--- 单发: su -c id ---"
  /data/local/tmp/sud -c id
  echo "rc1=$?"
  echo "--- 多条命令 + 重定向 ---"
  /data/local/tmp/sud -c 'echo HELLO; grep CapEff /proc/self/status; false'
  echo "rc2=$?"
  echo "--- 裸名 PATH 命中 ---"
  env PATH=/data/local/tmp:/system/bin sh -c 'command -v sud'
  echo "--- daemon 日志 ---"
  cat $L.daemon
  kill $DP 2>/dev/null
} >> $L 2>&1
cat $L
