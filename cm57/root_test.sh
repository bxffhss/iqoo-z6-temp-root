#!/system/bin/sh
# 在 ishell 的 root sh 里被喂进来执行(所以这里就是 uid0)。
# 问题: 会话结束(= pty 挂断)之后, 谁还活着?
#   D = setsid + nohup + 重定向  (脱开 tty)
#   P = 普通后台任务            (对照, 不脱 tty)
# 心跳里带自己的 pgrp/session/tty, 便于事后判断"它到底在不在那个 pty 的会话里"。
echo "ROOTSH_ENTER $(date +%T) uid=$(id -u) caps=$(grep -m1 CapEff /proc/self/status)"
echo "ROOTSH_SELF pgrp_session_tty=$(awk '{print $5"_"$6"_"$7}' /proc/self/stat)" 
cd /data/local/tmp 2>/dev/null || exit 9
rm -f detach.log plain.log
setsid nohup sh -c 'i=0; while [ $i -lt 30 ]; do echo "$(date +%T) DETACHED uid=$(id -u) i=$i pst=$(awk "{print \$5\"_\"\$6\"_\"\$7}" /proc/self/stat)" >> /data/local/tmp/detach.log; i=$((i+1)); sleep 20; done' </dev/null >/dev/null 2>&1 &
sh -c 'i=0; while [ $i -lt 30 ]; do echo "$(date +%T) PLAIN uid=$(id -u) i=$i pst=$(awk "{print \$5\"_\"\$6\"_\"\$7}" /proc/self/stat)" >> /data/local/tmp/plain.log; i=$((i+1)); sleep 20; done' &
echo SPAWNED_BOTH
