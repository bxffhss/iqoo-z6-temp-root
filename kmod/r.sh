#!/system/bin/sh
# r.sh —— 在白名单 app(Termux, uid 10667) 的 su 壳下，以 uid 0 重立 su 桥(shd)。
# 由 adb input text 在 Termux 里触发；复杂命令已在脚本内，避免 input text 吞掉 > & 等特殊符。
/product/bin/su -c 'setsid nohup /data/local/tmp/shd 31339 2147483647 10342 </dev/null >>/data/local/tmp/shd.log 2>&1 &'
sleep 1
echo R_DONE_PID_IS=$(/system/bin/pidof shd)
