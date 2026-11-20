#!/bin/bash
# z6_guard_host.sh — 主机侧双保险 guard（零 root）
# 用途：设备总控 z6_stage4.sh 若也被 framework 重建清掉，主机侧仍能靠 adb shell 打针 + 读 serial。
# 前提：probe2.jar 已 push、lspd 还活着（或总控已重起）。
# 用法: bash kmod/z6_guard_host.sh [秒数=150]
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>/dev/null | tr -d '\r'; }
DUR="${1:-150}"
END=$((SECONDS+DUR))
PROBE=/data/local/tmp/probe2.jar
MON=/data/adb/lspd/monitor

read_serial() { A "timeout 8 runcon u:r:shell:s0 service list 2>/dev/null | grep -a serial"; }

poke() {
  NAME=$(A "cat $MON 2>/dev/null")
  [ -z "$NAME" ] && { echo "[skip] monitor empty"; return 1; }
  A "timeout 6 app_process -Djava.class.path=$PROBE /system/bin Probe2 '$NAME' >/dev/null 2>&1" >/dev/null
  echo "[poke] name=$NAME rc=$? serial=[$(read_serial)]"
}

echo "=== HOST GUARD start dur=${DUR}s ts=$(date +%H:%M:%S) ==="
echo "device=$(adb get-state 2>/dev/null) boot_completed=$(A 'getprop sys.boot_completed')"
n=0
while [ $SECONDS -lt "$END" ]; do
  S=$(read_serial)
  case "$S" in
    *"[]"*) n=$((n+1)); if [ $((n % 15)) -eq 1 ]; then echo "[$(date +%H:%M:%S)] OK($n) serial=[$S]"; fi ;;
    *) echo "[$(date +%H:%M:%S)] re-arm serial=[$S]"; poke; n=0 ;;
  esac
  sleep 1
done
echo "=== HOST GUARD done final=[$(read_serial)] ==="
echo "lspd=[$(A 'pidof lspd')] zndaemon=[$(A 'pidof zn-daemon')]"
echo "module.prop=[$(A "grep -a '^description=' /data/adb/modules/zygisksu/module.prop")]"
