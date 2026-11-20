#!/system/bin/sh
# w310_kill.sh —— 第 107 发：把 #71 最后一枚 `/data/local/tmp/kd` 删掉并复证。
#   为什么这一发删得动而上一发不删：本发的主判据(第二个 app 走不走得通)已经出完(结果是"Manager 走 ksud、
#   被 app 域 seccomp 打死；suw 那格走的是 /product/bin/su 直路、不算干净的通用 su 复证")，
#   **接下来不再需要 su** ⇒ 可以在 Permissive 时段、翻执法之前把它带走(§6.230③ 记的就是这个次序死结)。
#   ★rmmod 不做：模块随 reboot 消失，而 rmmod 之后再想恢复就得再花一发。
O=/data/local/tmp/w310_kill.out
exec >>"$O" 2>&1
echo "=== W310 删残留 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c kernelsu /proc/modules) ==="
echo "  删之前："
ls -l /data/local/tmp/kd /data/local/tmp/ksud /data/local/tmp/sustatic /data/local/tmp/ksuctl88 2>&1 | tr -s ' ' | cut -d' ' -f1,3,5,9
for f in /data/local/tmp/kd /data/local/tmp/ksud /data/local/tmp/sustatic; do
    if [ -e "$f" ]; then rm "$f"; echo "  rm $f rc=$?"; else echo "  不在: $f"; fi
done
echo "  复证(应当三行都是 No such file)："
ls /data/local/tmp/kd /data/local/tmp/ksud /data/local/tmp/sustatic 2>&1
echo "  /data/adb 现状：[ $(ls /data/adb 2>&1 | tr '\n' ' ') ]"
echo "  改道参数指向的文件还在吗(kd 已删 ⇒ 本 boot 内 su 会 ENOENT)：$(ls -l /proc/ksu_install_fd >/dev/null 2>&1; echo 驱动口在=OK)"
echo "  目录里还剩什么(root-owned 的)：$(ls -l /data/local/tmp 2>&1 | awk '$3=="root"{print $9}' | tr '\n' ' ' | cut -c1-200)"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
