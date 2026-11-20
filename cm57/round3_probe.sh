#!/system/bin/sh
# round3_probe.sh — 在临时 root 窗口里把"运行时 su 层"搭起来并判每一格
L=/data/local/tmp/round3.log
rm -f $L /data/local/tmp/sud.log
exec >> $L 2>&1
echo "=== round3 su层 开始 uptime=$(cat /proc/uptime) ==="
id

echo "--- 1) 先把原 /product/bin 的三个文件搬出来 ---"
mkdir -p /data/local/tmp/prod_keep
cp -f /product/bin/* /data/local/tmp/prod_keep/ 2>&1
ls -l /data/local/tmp/prod_keep

echo "--- 2) tmpfs 覆盖挂载 /product/bin (故意不带 nosuid/noexec) ---"
mount -t tmpfs -o rw,mode=0755 tmpfs /product/bin
echo "mount_rc=$?"
grep ' /product/bin ' /proc/mounts

echo "--- 3) 原文件放回 + 装 su ---"
cp -f /data/local/tmp/prod_keep/* /product/bin/
cp -f /data/local/tmp/sud /product/bin/su
chmod 755 /product/bin/*
ls -l /product/bin

echo "--- 4) 起 daemon(带监督循环, 挂了自动复活) + uid0 心跳 ---"
setsid nohup sh -c 'while :; do /data/local/tmp/sud --daemon; echo "[sud] 退出, 2s 后重来" ; sleep 2; done' </dev/null >>/data/local/tmp/sud.log 2>&1 &
setsid nohup sh -c 'i=0; while [ $i -lt 240 ]; do echo "hb $i uptime=$(cat /proc/uptime)" >>/data/local/tmp/hb.log; i=$((i+1)); sleep 15; done' </dev/null >/dev/null 2>&1 &
sleep 2
echo "sud.log:"; cat /data/local/tmp/sud.log
ps -A -o PID,UID,PPID,NAME | grep -wE 'sud|sh' | head -6

echo "--- 5) ★关键未知: zygote 的 mount namespace 看不看得到我们的挂载 ---"
Z=$(pidof zygote64)
echo "zygote64 pid=$Z"
echo "本进程 mountinfo 里 product 行数=$(grep -c product /proc/self/mountinfo)"
echo "zygote mountinfo 里 product 行数=$(grep -c product /proc/$Z/mountinfo)"
grep ' /product/bin ' /proc/$Z/mountinfo
echo "app(com.user.app) mountinfo 里 product 行数=$(grep -c product /proc/$(pidof com.user.app)/mountinfo)"

echo "--- 6) root 侧自测 su 通路 + SIGPIPE 回归测试(上一版就是这么死的) ---"
/product/bin/su -c id
echo "su_rc=$?"
echo "[6a] 故意让 shim 提前退出(消费者只取一行) => 旧版会在这一步把 daemon 打死"
/product/bin/su -c 'for i in 1 2 3 4 5; do echo out-$i; sleep 1; done' | head -1
sleep 3
echo "[6b] daemon 还活着吗:"
ps -A -o PID,UID,NAME | grep -w sud
echo "[6c] 再走一次, 应当成功:"
/product/bin/su -c 'echo ALIVE-AGAIN'
echo "rc6c=$?"
echo "--- 6b) 用 app 一样的 PATH 走裸名 su(还是 root uid, 只验 PATH 命中) ---"
env PATH=/product/bin:/system/bin sh -c 'command -v su; su -c "id; grep CapEff /proc/self/status"'

echo "--- 7) setresuid 的观察改到窗口外由 uid2000 做(suverify2 的 B 段): root 会话里 am 找不到 activity 服务 ---"
echo "(本轮此处不建 kprobe)"

echo "--- 8) 现场快照(收尾要靠它) ---"
cat /proc/mounts | grep ' /product/bin '
getenforce
echo "=== round3 结束 uptime=$(cat /proc/uptime) ==="
sync
