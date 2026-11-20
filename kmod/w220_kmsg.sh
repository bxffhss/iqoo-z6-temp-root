#!/system/bin/sh
# w220_kmsg.sh — 纯只读：找 daemon 死因 + init hook 是否还在 + 精确时间线
# ★不 am start、不 kill、不写服务、不改任何状态
OUT=/data/local/tmp/w220_kmsg.out
exec >"$OUT" 2>&1
echo "ts=$(date +%Y-%m-%dT%H:%M:%S)"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) up=$(cut -d' ' -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(cat /sys/fs/selinux/enforce)"

echo "########## [1] ★内核日志通道可读性 ##########"
echo "dmesg_restrict=$(cat /proc/sys/kernel/dmesg_restrict 2>&1)"
echo "kptr_restrict=$(cat /proc/sys/kernel/kptr_restrict 2>&1)"
echo "--- dmesg tail 60 ---"
timeout 8 dmesg 2>&1 | tail -60
echo "DMESG_RC=$?"
echo "--- logcat -b kernel (last 40) ---"
timeout 8 logcat -d -b kernel -t 200 2>&1 | tail -40

echo "########## [2] ★找 01:01 前后的进程死亡记录 ##########"
echo "--- dmesg 全量 grep (kill/sig/lmkd/oom/exit/zygisk/lspd) ---"
timeout 10 dmesg 2>/dev/null | grep -aiE 'sigkill|kill -9|lmkd|lowmemory|oom|out of memory|zygisk|zn-daemon|lspd|init: Service|zygote|system_server|KSUBEAT|KernelSU' | tail -80
echo "--- logcat -b all 同族 ---"
timeout 10 logcat -d -b all -t 3000 2>/dev/null | grep -aiE 'zygisk|zn-daemon|lspd|LSPosed|zygote.*die|process.*died|killProcess|am_proc_died|lowmemory' | tail -60

echo "########## [3] ★/proc/1/maps：ZygiskNext 注入 init 的 hook 还在吗 ##########"
echo "--- init maps anon/payload 段（DAC 可能挡，如实标注） ---"
grep -aE 'libpayload|libzygisk|zn_|anon_inode|/dev/zero' /proc/1/maps 2>&1 | head -20
echo "--- init maps 可读性 ---"; head -3 /proc/1/maps 2>&1
echo "--- zygote maps 可读性 ---"; head -3 /proc/$(pidof zygote64)/maps 2>&1
echo "--- init fd 数 / wchan ---"; ls /proc/1/fd 2>/dev/null | wc -l; cat /proc/1/wchan 2>&1; echo

echo "########## [4] ★精确时间线：所有相关文件 mtime ##########"
for f in /data/adb/zygisksu/.magic /data/adb/zygisksu/modules_info /data/adb/zygisksu/znctx \
         /data/adb/modules/zygisksu/module.prop /data/adb/modules/zygisksu/module.prop.orig \
         /data/adb/lspd/monitor /data/adb/lspd/log/kmsg.log /data/adb/lspd/log/verbose_*.log \
         /data/adb/lspd/log/modules_*.log /data/adb/lspd/log/props.txt \
         /data/local/tmp/w215_kick.out /data/local/tmp/w216_verify.out \
         /data/local/tmp/w217_diag.out /data/local/tmp/w218_probe.out /data/local/tmp/w219_dig.out; do
  ls -la --full-time "$f" 2>/dev/null
done
echo "--- ksu/log 目录（ZN post-fs-data 会往这 cp） ---"
ls -la --full-time /data/adb/ksu/log/ 2>&1 | head -20

echo "########## [5] ★lspbridge socket 是否还在 ##########"
echo "--- monitor 值 ---"; cat /data/adb/lspd/monitor 2>&1; echo
echo "--- /proc/net/unix 里 lspbridge / zn / lspd ---"
grep -aE 'lspbridge|lspd|zn_|zygisk' /proc/net/unix 2>&1 | head -20
echo "unix_total=$(wc -l < /proc/net/unix 2>/dev/null)"

echo "########## [6] service list 里的 LSPosed 痕迹（全量过滤） ##########"
timeout 12 service list 2>/dev/null | grep -aiE 'lsp|xposed|dex2oat|bridge|serial|zygisk' | head -20

echo "########## [7] props.txt 头部（判断它是什么） ##########"
head -20 /data/adb/lspd/log/props.txt 2>&1

echo "########## [8] 当前进程/窗口复核（确认这轮只读没动过） ##########"
echo "zygote64=$(pidof zygote64) start_ticks=$(awk '{print $22}' /proc/$(pidof zygote64)/stat 2>/dev/null)"
echo "boot_completed=$(getprop sys.boot_completed) vivo.zygote_restart=$(getprop vivo.zygote_restart)"
echo "lspd=[$(pidof lspd)] zndaemon=[$(pidof zn-daemon)] suw=[$(pidof com.suw.manager)]"
echo "===== DONE"
