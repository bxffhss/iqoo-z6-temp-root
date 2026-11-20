#!/system/bin/sh
# w211_prep.sh — 踢 zygote 前的最后准备 + 收窗风险评估（只读为主，不碰 zygote）
OUT=/data/local/tmp/w211_prep.out
exec >"$OUT" 2>&1
M=/data/adb/modules
ZN=$M/zygisksu
LP=$M/zygisk_lsposed
BB=/data/adb/ksu/bin/busybox

echo "########## [1] current window state ##########"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
echo "up=$(cut -d' ' -f1 /proc/uptime) boot_completed=$(getprop sys.boot_completed)"
echo "enf=$(cat /sys/fs/selinux/enforce) mod=$(grep -c kernelsu /proc/modules)"
echo "zygote64=$(pidof zygote64) zygote=$(pidof zygote) system_server=$(pidof system_server)"
echo "lspd=$(pidof lspd) zn-daemon=$(pidof zn-daemon) suw=$(pidof com.suw.manager)"
echo "--- zygote starttime (CLK_TCK=100) ---"
awk '{print "zygote64 start_ticks=" $22}' /proc/$(pidof zygote64)/stat 2>/dev/null

echo "########## [2] ★收窗风险评估：@sushd 腿相关 ##########"
echo "--- ksu_race_fd 看门狗进程 (PPID=1 则 zygote 重启后仍在) ---"
ps -A -o PID,PPID,UID,NAME,CMD 2>/dev/null | grep -aiE 'race|fdwatch|shd|ksuctl|stage' | head -30
echo "--- /data/local/tmp/ksu_race_fd 开关在否 ---"
ls -la /data/local/tmp/ksu_race_fd 2>&1
echo "--- pbin (root 建的 su 拷贝，shell 删不动) ---"
ls -la /data/local/tmp/pbin/ 2>&1
echo "--- /data/adb/ksu/.allowlist (残留会污染下一发) ---"
ls -la /data/adb/ksu/.allowlist 2>&1
echo "--- com.suw.manager PPID (=zygote 则必被杀) ---"
for p in $(pidof com.suw.manager); do awk -v pid=$p '{print "pid="pid" ppid="$4}' /proc/$p/stat; done

echo "########## [3] ★验证通道：znctl status 从 shell(uid2000) 能否读 ##########"
timeout 8 "$ZN/bin/zygiskd" status 2>&1 | grep -aE 'version:|zygote_states|inject_state|root_status|modules' ; echo "SHELL_ZNCTL_RC=$?"

echo "########## [4] LSPosed 离线 license (sign_tool -l, 本地无需网) ##########"
ST="$LP/bin/arm64-v8a/sign_tool"
chmod 0755 "$ST"
mkdir -p /data/adb/lspd
echo "--- sign_tool exists? ---"; ls -la "$ST"
echo "--- package.pb ---"; ls -la "$LP/package.pb"
timeout 20 "$ST" -l "$LP/package.pb" /data/adb/lspd/license.pb 2>&1; echo "SIGN_RC=$?"
echo "--- license.pb after ---"; ls -la /data/adb/lspd/license.pb 2>&1

echo "########## [5] LSPosed 运行件完整性 ##########"
for f in daemon lspd daemon.apk framework.dex zn_modules.txt zygisk/arm64-v8a.so zygisk/armeabi-v7a.so lib/libpreload64.so lib/libpreload32.so bin/dex2oat64 bin/dex2oat32 machikado mazoku; do
  if [ -e "$LP/$f" ]; then echo "OK   $f ($(wc -c < "$LP/$f") B)"; else echo "MISS $f"; fi
done
echo "--- /data/adb/lspd/config 现有 db ---"
ls -la /data/adb/lspd/config/ 2>&1

echo "########## [6] 起 lspd daemon (不等 zygote，先让 Java 服务就位) ##########"
# service.sh 语义：清 tmp apk → daemon --force &（daemon 再 exec lspd）
rm -f /data/local/tmp/daemon.apk /data/local/tmp/manager.apk
cd "$LP" || exit 1
nohup "$BB" setsid "$LP/daemon" --force >/data/local/tmp/w211_lspd.log 2>&1 </dev/null &
echo "LSPD_SPAWN_PID=$!"
sleep 5
echo "--- lspd processes ---"
ps -A -o PID,PPID,UID,NAME | grep -aiE 'lspd|app_process'
echo "--- lspd log ---"; cat /data/local/tmp/w211_lspd.log
echo "--- LSPosed logcat ---"
logcat -d -t 250 2>/dev/null | grep -aiE 'LSPosed|lspd|lspd-|license|LSPosedBridge' | tail -40

echo "########## [7] ZygiskNext status after lspd ##########"
timeout 8 "$ZN/bin/zygiskd" status 2>&1 | grep -aE 'version:|zygote_states|inject_state|root_status|modules'; echo "RC=$?"
echo "===== DONE"
