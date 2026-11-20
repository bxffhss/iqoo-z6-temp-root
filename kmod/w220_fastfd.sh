#!/system/bin/sh
# w220_fastfd.sh —— 在**一条腿里**把"重启官方 + 抢在启动查询之前装 fd"两步的间隔压到 ~1.2s。
#   为什么要它：§6.219 一手 —— 先 `am start` 再用 PC 侧发腿去写 fd，写下去时官方已经渲染成「不支持」
#   (fd 确实在进程里：`6 -> anon_inode:[ksu_driver]`，但那次查询是启动时一次性分支，晚到不重查)。
#   而老办法 `w196_fire.sh` 是靠一个 0.4s 轮询的看门狗去追新 pid —— 那条循环正是 §6.218④ 的嫌疑人。
#   ⇒ 这一条只写**一次**、不轮询、进程内计时：拿到时序，但不引入那个变量。
L=/data/local/tmp/w220_fastfd.out
exec >>"$L" 2>&1
PKG=me.weishu.kernelsu
echo "=== W220 起窗 up=$(cut -d' ' -f1 /proc/uptime) 我自己=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) ==="
[ -e /proc/ksu_install_fd ] || { echo "[x] /proc/ksu_install_fd 不在"; echo "=== DONE ==="; exit 0; }
am force-stop $PKG
am start -n $PKG/.ui.MainActivity >/dev/null 2>&1
# ★紧捕获：0.1s 一轮、命中立刻写(实测新 pid 出现在 +0.57s)。§6.219②：隔 ~10s 再写就赶不上启动那次查询。
#   注意这**不是** `w196_fire.sh` 那个 160s 轮询看门狗(§6.218④ 的嫌疑人)：最长 2s、命中即退、只写一次。
MP=
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    MP=$(pidof $PKG | cut -d' ' -f1)
    [ -n "$MP" ] && break
    sleep 0.1
done
echo "轮=$i 新 pid=[$MP] up=$(cut -d' ' -f1 /proc/uptime)"
[ -n "$MP" ] || { echo "[x] 没起起来 ⇒ 不写(空串写进去会把账弄脏)"; echo "=== DONE ==="; exit 0; }
echo "$MP" > /proc/ksu_install_fd
echo "写下去 rc=$?"
sleep 2
echo "复查: fd 总数=$(ls -1 /proc/$MP/fd 2>/dev/null | wc -l) 含 ksu_driver=$(ls -l /proc/$MP/fd 2>/dev/null | grep -ac ksu_driver) 进程还在=$(ls -d /proc/$MP >/dev/null 2>&1 && echo Y || echo N)"
echo "pid 没变过吗(变了=它自己重起过一次，那 fd 就白装了): $(pidof $PKG | tr ' ' ',')"
echo "=== DONE up=$(cut -d' ' -f1 /proc/uptime) ==="
chmod 666 "$L" 2>/dev/null
