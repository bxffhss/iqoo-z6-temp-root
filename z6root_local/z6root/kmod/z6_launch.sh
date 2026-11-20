#!/system/bin/sh
# z6_launch.sh — 经 @sushd 触发：只负责把 z6_stage4.sh 完全脱离地启起来，然后立即返回 DONE
# ★不能在这里跑任何长动作：sushd 的宿主是 com.suw.manager(zygote 子进程)，踢框架后必死
OUT=/data/local/tmp/z6_launch.out
exec >"$OUT" 2>&1
echo "ts=$(date +%Y-%m-%dT%H:%M:%S) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null)"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) mod=$(grep -c kernelsu /proc/modules) enf=$(cat /sys/fs/selinux/enforce)"

# 前置件核对（没齐就不发）
MISS=0
for f in /data/local/tmp/z6_stage4.sh /data/local/tmp/probe2.jar \
         /data/adb/modules/zygisksu/bin/zygiskd /data/adb/modules/zygisk_lsposed/daemon; do
  if [ -e "$f" ]; then echo "OK   $f"; else echo "MISS $f"; MISS=$((MISS+1)); fi
done
if [ "$MISS" -ne 0 ]; then echo "### ABORT missing=$MISS"; echo "===== DONE"; exit 1; fi

chmod 755 /data/local/tmp/z6_stage4.sh
chmod 644 /data/local/tmp/probe2.jar
: > /data/local/tmp/z6_stage4.log; chmod 666 /data/local/tmp/z6_stage4.log

# 双 fork + setsid：子 shell 立即退出，孙进程被 init 收养；总控脚本内部再做 cgroup 加固
# ★用系统 /system/bin/setsid：/data/adb/ksu/bin/busybox 会被收窗删掉(实测不可访问)
( /system/bin/setsid sh /data/local/tmp/z6_stage4.sh >/dev/null 2>&1 </dev/null & )
echo "LAUNCHED ts=$(date +%H:%M:%S)"
sleep 8
echo "--- stage4 log head (证明总控真的起来了) ---"
head -20 /data/local/tmp/z6_stage4.log 2>&1
echo "--- stage4 proc ---"
ps -A -o PID,PPID,UID,NAME,CMD 2>/dev/null | grep -a 'z6_stage4' | grep -av grep | head -5
echo "===== DONE"
