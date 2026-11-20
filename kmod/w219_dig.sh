#!/system/bin/sh
# w219_dig.sh — 留窗只读深挖：daemon 被谁清 / respawn 可行性 / probe2 替代 / root 腿
# ★纯只读，不 reboot、不 am start、不写任何设备状态
OUT=/data/local/tmp/w219_dig.out
exec >"$OUT" 2>&1
echo "ts=$(date +%Y-%m-%dT%H:%M:%S)"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) up=$(cut -d' ' -f1 /proc/uptime)"
echo "boot_completed=$(getprop sys.boot_completed) enf=$(cat /sys/fs/selinux/enforce) mod=$(grep -c kernelsu /proc/modules)"

echo "########## [1] ★init.zygote*.rc: onrestart / class / critical（解释清理范围） ##########"
for f in /system/etc/init/hw/init.zygote*.rc /vendor/etc/init/hw/init.zygote*.rc; do
  [ -f "$f" ] || continue
  echo "--- $f ---"
  grep -aE '^(service|onrestart|    (class|oneshot|critical|priority|user|group|socket))' "$f" 2>/dev/null
done
echo "--- 所有含 'zygote' 的 init rc 里的 onrestart 行（找 class_reset / killProcessGroup） ---"
grep -raE 'onrestart|class_reset|class_stop|restart zygote|killProcessGroup' /system/etc/init/ /vendor/etc/init/ 2>/dev/null | grep -aiE 'zygote|class_reset|class_stop' | head -50

echo "########## [2] ★framework 重建期内核日志（kmsg.log 0666 可读） ##########"
K=/data/adb/lspd/log/kmsg.log
if [ -r "$K" ]; then
  echo "--- kmsg.log size ---"; wc -c "$K"
  echo "--- 01:00~01:03 段的关键行 ---"
  grep -aE 'zygote|system_server|KSU|KernelSU|ksud|SELinux|avc|kill|sigkill|watchdog|lmkd|lowmemory|oom|init:|libzygisk|lspd' "$K" 2>/dev/null | tail -80
else
  echo "kmsg.log NOT readable from shell"
fi

echo "########## [3] LSPosed 侧残留（0666 件） ##########"
echo "--- monitor ---"; cat /data/adb/lspd/monitor 2>&1; echo
echo "--- props.txt 尾部（LSPosed 自己 dump 的属性） ---"; tail -30 /data/adb/lspd/props.txt 2>&1
echo "--- lspd log 目录权限总览 ---"; ls -la /data/adb/lspd/log/ 2>&1 | head -20

echo "########## [4] tombstones：framework 重建期有无新 crash ##########"
ls -lat /data/tombstones/ 2>/dev/null | head -12
LATEST=$(ls -t /data/tombstones/tombstone_[0-9]* 2>/dev/null | grep -v '\.pb' | head -1)
echo "LATEST=$LATEST"
if [ -n "$LATEST" ]; then
  echo "--- head 25 ---"; head -25 "$LATEST" 2>&1
  echo "--- Cmdline/signal ---"; grep -aE 'Cmdline:|signal [0-9]|Cause:|pid:' "$LATEST" 2>/dev/null | head -12
fi

echo "########## [5] ★logcat 全 buffer（framework 重启后 logd 是否被重置） ##########"
echo "total_lines=$(logcat -d -t 5000 2>/dev/null | wc -l)"
echo "earliest=$(logcat -d -t 5000 2>/dev/null | head -1 | cut -c1-90)"
echo "latest=$(logcat -d -t 5000 2>/dev/null | tail -1 | cut -c1-90)"
echo "--- zygote/framework restart markers ---"
logcat -d -t 5000 2>/dev/null | grep -aiE 'Zygote|system_server|Watchdog|boot_completed|zygisk|LSPosed|lspd|ksud|KernelSU' | head -40

echo "########## [6] ★service list 全量（LSPosed 有无注册任何服务） ##########"
timeout 12 service list 2>/dev/null | grep -aiE 'lsp|serial|xposed|zygisk|dex2oat|bridge' | head -30
echo "service_total=$(timeout 12 service list 2>/dev/null | wc -l)"

echo "########## [7] ★残留 root 运行时件（下一发能否复用） ##########"
for f in /data/local/tmp/sustatic /data/local/tmp/asuid /data/local/tmp/kd /data/local/tmp/ksuctl88 /data/local/tmp/ksud /data/adb/ksud /data/adb/ksu/bin/ksud; do
  ls -la "$f" 2>&1
done
echo "--- ksuctl88 info from shell ---"
timeout 6 /data/local/tmp/ksuctl88 info 2>&1 | tail -8
echo "--- ksu proc nodes perms ---"; ls -la /proc/ksu_install_fd /proc/ksu_slots 2>&1

echo "########## [8] ★cgroup / oom：daemon 能否躲过清理 ##########"
echo "--- cgroup 挂载 ---"; grep -aE 'cgroup' /proc/mounts 2>/dev/null | head -15
echo "--- init cgroup ---"; cat /proc/1/cgroup 2>&1
echo "--- shell self cgroup ---"; cat /proc/self/cgroup 2>&1
echo "--- zygote cgroup ---"; cat /proc/$(pidof zygote64)/cgroup 2>&1
echo "--- zygote oom_score_adj ---"; cat /proc/$(pidof zygote64)/oom_score_adj 2>&1
echo "--- system_server cgroup ---"; cat /proc/$(pidof system_server)/cgroup 2>&1
echo "--- /sys/fs/cgroup 顶层 ---"; ls -la /sys/fs/cgroup/ 2>&1 | head -20
echo "--- init 下 PPID=1 非内核进程（看什么样能活） ---"
ps -A -o PID,PPID,UID,NAME 2>/dev/null | awk '$2==1 && $1>100 {print}' | head -40

echo "########## [9] ★init 能否被借来 respawn（stock init.rc 只读，找可用 property trigger） ##########"
echo "--- 现有 init property trigger 里 boot_completed 相关 ---"
grep -raE 'on property:sys.boot_completed|on property:init.svc.zygote|on property:sys.boot_completed=1' /system/etc/init/ /vendor/etc/init/ 2>/dev/null | head -20
echo "--- /system/etc/init 可写?（overlay 可行性） ---"
ls -ld /system/etc/init /system/etc/init/hw 2>&1
echo "--- 当前 overlay 挂载（go.sh 加过哪些文件） ---"
grep -aE 'overlay|/product/bin/su|system/etc' /proc/mounts 2>/dev/null | head -20

echo "########## [10] 模块现状（下一发是否要重装） ##########"
echo "--- zygisksu ---"; ls -la /data/adb/modules/zygisksu/ 2>&1 | head -25
echo "--- zygisk_lsposed ---"; ls -la /data/adb/modules/zygisk_lsposed/ 2>&1 | head -25
echo "--- 备份目录（可回滚） ---"; ls -ld /data/adb/modules/.*bak /data/adb/modules/.rebuild 2>&1

echo "########## [11] 只读确认窗口仍完整 ##########"
echo "zygote64=$(pidof zygote64) start_ticks=$(awk '{print $22}' /proc/$(pidof zygote64)/stat 2>/dev/null)"
echo "lspd=[$(pidof lspd)] zndaemon=[$(pidof zn-daemon)] suw=[$(pidof com.suw.manager)]"
echo "===== DONE"
