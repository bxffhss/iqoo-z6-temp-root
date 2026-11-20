#!/system/bin/sh
# w212_lspd.sh — 查 lspd crash 栈 + sign_tool 用法 + 用 system_server 域重试 lspd
OUT=/data/local/tmp/w212_lspd.out
exec >"$OUT" 2>&1
M=/data/adb/modules
LP=$M/zygisk_lsposed
BB=/data/adb/ksu/bin/busybox

echo "########## [1] latest tombstone (lspd crash stack) ##########"
LATEST=$(ls -t /data/tombstones/tombstone_[0-9]* 2>/dev/null | grep -v '\.pb' | head -1)
echo "LATEST=$LATEST"
if [ -n "$LATEST" ]; then
  echo "--- head 60 ---"; head -60 "$LATEST" 2>&1
  echo "--- backtrace signal lines ---"; grep -aE 'signal|Cmdline|backtrace|#0[0-9]|lspd|liblspd|libframework|abort message' "$LATEST" 2>&1 | head -60
fi

echo "########## [2] LSPosed verbose log (root 可读) ##########"
VL=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | head -1)
echo "VERBOSE=$VL"
[ -n "$VL" ] && tail -80 "$VL" 2>&1
echo "--- modules log ---"
ML=$(ls -t /data/adb/lspd/log/modules_*.log 2>/dev/null | head -1)
echo "MODULES=$ML"
[ -n "$ML" ] && tail -30 "$ML" 2>&1

echo "########## [3] sign_tool usage ##########"
ST="$LP/bin/arm64-v8a/sign_tool"
timeout 8 "$ST" 2>&1; echo "ST_NOARG_RC=$?"
echo "--- help ---"
timeout 8 "$ST" --help 2>&1; echo "ST_HELP_RC=$?"
echo "--- strings of interest (license/usage flags) ---"
grep -aoE '[[:print:]]{5,}' "$ST" 2>/dev/null | grep -aiE 'usage|license|skip|offline|sign_tool|-l |--|package.pb|Skipped|request' | sort -u | head -60

echo "########## [4] retry lspd with system_server context (Z5 recipe) ##########"
pkill -9 -f 'lspd' 2>/dev/null
sleep 1
rm -f /data/local/tmp/daemon.apk /data/local/tmp/manager.apk
cd "$LP" || exit 1
echo "--- current domain ---"; cat /proc/self/attr/current
nohup "$BB" setsid runcon u:r:system_server:s0 sh -c "cd $LP && exec ./daemon --force" >/data/local/tmp/w212_lspd.log 2>&1 </dev/null &
echo "LSPD2_SPAWN_PID=$!"
sleep 6
echo "--- lspd processes ---"
ps -A -o PID,PPID,UID,NAME | grep -aiE 'lspd|app_process'
echo "--- lspd log ---"; cat /data/local/tmp/w212_lspd.log
echo "--- LSPosed logcat (fresh) ---"
logcat -d -t 200 2>/dev/null | grep -aiE 'LSPosed|lspd|LSPosedService|LSPosedBridge' | tail -50

echo "########## [5] is LSPosed service registered? ##########"
echo "--- service list | grep serial/lspd ---"
timeout 10 runcon u:r:shell:s0 service list 2>&1 | grep -aiE 'serial|lspd|lsposed'
echo "SERVICE_RC=$?"

echo "########## [6] zn status still intact ##########"
timeout 8 "$M/zygisksu/bin/zygiskd" status 2>&1 | grep -aE 'version:|zygote_states|inject_state|modules'; echo "RC=$?"
echo "===== DONE"
