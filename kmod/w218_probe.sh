#!/system/bin/sh
# w218_probe.sh — 踢后最终判据：UI 激活状态 / daemon 能否从 shell 重起 / sushd 腿是否还在
# 纯 shell 只读 + 无害重起尝试
OUT=/data/local/tmp/w218_probe.out
exec >"$OUT" 2>&1
ZN=/data/adb/modules/zygisksu/bin/zygiskd
echo "ts=$(date +%Y-%m-%dT%H:%M:%S)"

echo "########## [1] ★LSPosed Manager UI 激活状态 ##########"
am start -n org.lsposed.manager/.ui.activity.MainActivity >/dev/null 2>&1
sleep 5
uiautomator dump /sdcard/w218_ui.xml >/dev/null 2>&1
echo "DUMP_RC=$?"
if [ -f /sdcard/w218_ui.xml ]; then
  echo "--- UI text (activation keywords) ---"
  grep -aoE 'text="[^"]*"' /sdcard/w218_ui.xml 2>/dev/null | grep -aiE '激活|已启用|未激活|active|LSPosed|Zygisk|版本|模块|manager' | head -40
  echo "--- all text (first 60) ---"
  grep -aoE 'text="[^"]*"' /sdcard/w218_ui.xml 2>/dev/null | head -60
else
  echo "UI_DUMP_MISSING"
fi

echo "########## [2] ★shell 能否重新拉起 zn-daemon ##########"
echo "--- try zygiskd daemon from shell (uid 2000) ---"
timeout 10 "$ZN" daemon 2>&1; echo "DAEMON_RC=$?"
sleep 2
echo "--- zndaemon after ---"; pidof zn-daemon
echo "--- status after ---"
timeout 8 "$ZN" status 2>&1 | grep -aE 'version:|zygote_states|inject_state|root_status|modules|err:|failed'; echo "STATUS_RC=$?"
echo "--- sockets ---"; grep -acE 'zn_|lspd|lspbridge' /proc/net/unix 2>/dev/null

echo "########## [3] ★@sushd 腿是否还能用（无害 echo 脚本） ##########"
cat > /data/local/tmp/w218_sushd_probe.sh <<'PROBE_EOF'
#!/system/bin/sh
echo "SUSHD_ALIVE ts=$(date +%H:%M:%S) uid=$(id -u) ctx=$(cat /proc/self/attr/current)" > /data/local/tmp/w218_sushd_probe.out
echo "===== DONE" >> /data/local/tmp/w218_sushd_probe.out
PROBE_EOF
chmod 755 /data/local/tmp/w218_sushd_probe.sh
rm -f /data/local/tmp/w218_sushd_probe.out
am force-stop com.suw.manager >/dev/null 2>&1; sleep 1
am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd '@sushd:/data/local/tmp/w218_sushd_probe.sh' 2>&1 | head -3
sleep 6
echo "--- sushd probe result ---"; cat /data/local/tmp/w218_sushd_probe.out 2>&1

echo "########## [4] 注入是否曾发生（间接判据） ##########"
echo "--- modules_info / znctx mtime (00:39 = 未随 kick 更新) ---"
ls -la --full-time /data/adb/zygisksu/znctx /data/adb/zygisksu/modules_info /data/adb/zygisksu/.magic 2>&1
echo "--- LSPosed modules log (需 root，shell 读不到则标注) ---"
ML=$(ls -t /data/adb/lspd/log/modules_*.log 2>/dev/null | head -1)
echo "MODULES_LOG=$ML"; cat "$ML" 2>&1 | head -20
echo "--- logcat buffer size / any zn lines at all ---"
logcat -d -t 500 2>/dev/null | wc -l
logcat -d -t 500 2>/dev/null | grep -aicE 'zn-daemon|zygisk|LSPosed|lspd'

echo "########## [5] 窗口现状 ##########"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) up=$(cut -d' ' -f1 /proc/uptime)"
echo "boot_completed=$(getprop sys.boot_completed) enf=$(cat /sys/fs/selinux/enforce) mod=$(grep -c kernelsu /proc/modules)"
echo "zygote64=$(pidof zygote64) start_ticks=$(awk '{print $22}' /proc/$(pidof zygote64)/stat 2>/dev/null)"
echo "===== DONE"
