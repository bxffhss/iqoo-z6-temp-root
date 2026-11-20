#!/system/bin/sh
# w215_kick.sh — 最后一发：重启 zygote 触发 ZygiskNext 注入
# ★设计：本脚本只写前置读数 + 布下一个完全脱离的延迟 killer，立即返回 DONE。
#   不在本脚本里直接 kill（会连 @sushd 宿主 com.suw.manager 一起干掉、读数写不全）。
OUT=/data/local/tmp/w215_kick.out
exec >"$OUT" 2>&1
ZN=/data/adb/modules/zygisksu/bin/zygiskd
BB=/data/adb/ksu/bin/busybox

echo "########## PRE-STATE (before kick) ##########"
echo "ts=$(date +%Y-%m-%dT%H:%M:%S)"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
echo "up=$(cut -d' ' -f1 /proc/uptime)"
echo "boot_completed=$(getprop sys.boot_completed)"
echo "enf=$(cat /sys/fs/selinux/enforce) mod=$(grep -c kernelsu /proc/modules)"
echo "zygote64=$(pidof zygote64) zygote=$(pidof zygote) system_server=$(pidof system_server)"
echo "zygote64_start=$(awk '{print $22}' /proc/$(pidof zygote64)/stat 2>/dev/null)"
echo "lspd=[$(pidof lspd)] zndaemon=[$(pidof zn-daemon)] suw=[$(pidof com.suw.manager)]"
echo "--- zn status BEFORE ---"
timeout 6 "$ZN" status 2>&1; echo "STATUS_RC=$?"

echo "########## sanity gates ##########"
# 只在这些条件全满足时才允许发射
GATE=OK
[ "$(getprop sys.boot_completed)" = "1" ] || GATE="FAIL:boot_completed!=1"
[ "$(cat /sys/fs/selinux/enforce)" = "0" ] || GATE="FAIL:enforcing"
[ "$(grep -c kernelsu /proc/modules)" -ge 1 ] || GATE="FAIL:ko_gone"
[ -n "$(pidof zn-daemon)" ] || GATE="FAIL:zn_daemon_gone"
[ -n "$(pidof lspd)" ] || GATE="FAIL:lspd_gone"
echo "GATE=$GATE"

if [ "$GATE" != "OK" ]; then
  echo "### ABORT: gate failed, killer NOT armed"
  echo "===== DONE"
  exit 1
fi

echo "########## arm delayed killer (3s, fully detached) ##########"
cat > /data/local/tmp/w215_killer.sh <<'KILLER_EOF'
#!/system/bin/sh
sleep 3
P64=$(pidof zygote64)
P32=$(pidof zygote)
PSS=$(pidof system_server)
echo "KICK target system_server=$PSS zygote64=$P64 zygote=$P32 ts=$(date +%H:%M:%S)" >> /data/local/tmp/w215_kick.out
kill -9 $PSS $P64 $P32 2>/dev/null
echo "KICK rc=$? ts=$(date +%H:%M:%S)" >> /data/local/tmp/w215_kick.out
KILLER_EOF
chmod 755 /data/local/tmp/w215_killer.sh
# 双 fork + setsid 脱离会话/进程组，孙进程被 init 收养，不受 com.suw.manager 被杀影响
( "$BB" setsid sh /data/local/tmp/w215_killer.sh >/dev/null 2>&1 </dev/null & )
echo "ARMED ts=$(date +%H:%M:%S)"
echo "===== DONE"
