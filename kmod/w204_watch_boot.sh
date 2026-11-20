#!/bin/bash
# w204_watch_boot.sh —— 后台腿：等这一次 reboot 起完，自动把风暴计数器挂上(shell 身份，不碰王座)。
#   为什么要它：上一发是我手工轮询，结果晚挂了 370 秒(计数器从 up=605 才开始采)，差点错过风暴。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
upint() { local r; r=$(A "cut -d' ' -f1 /proc/uptime" | tr -d '\r' | tr -dc '0-9.'); echo "${r%%.*}"; }   # ★小数点必须留着再切：`tr -dc 0-9` 会把 "271.68" 挤成 "27168"(放大 100 倍)
echo "[w204] 等 reboot(现在 up=$(upint))"
for i in $(seq 1 150); do
    up=$(upint)
    if [ -n "$up" ] && [ "$up" -lt 400 ]; then echo "[w204] 看到新 boot i=$i up=$up"; break; fi
    sleep 5
done
for i in $(seq 1 60); do
    bc=$(A "getprop sys.boot_completed" | tr -dc '0-9')
    [ "$bc" = 1 ] && { echo "[w204] boot_completed=1 (第 $i 轮)"; break; }
    sleep 5
done
sleep 20
adb push kmod/w201_stormwatch.sh /data/local/tmp/w201_stormwatch.sh >/dev/null 2>&1
A "WUID=0 RISE=30 N=900 SLEEP_S=2 L=/data/local/tmp/w204_storm.txt PIDF=/data/local/tmp/w204_storm.pid setsid sh /data/local/tmp/w201_stormwatch.sh >/dev/null 2>&1 &" >/dev/null
sleep 6
echo "[w204] 计数器 pid=$(A 'cat /data/local/tmp/w204_storm.pid 2>/dev/null' | tr -dc '0-9') up=$(upint)"
A "head -3 /data/local/tmp/w204_storm.txt 2>/dev/null" | sed 's/^/         /'
echo "[w204] ===== W204-DONE ====="
