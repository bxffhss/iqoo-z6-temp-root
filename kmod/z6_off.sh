#!/bin/bash
# z6_off.sh — 收窗（把临时 root 窗口干净收回出厂态）
#   原理：ko 是内核模块，reboot 即卸载 ⇒ SELinux 回 Enforcing、/product/bin bind 消失、名单清空。
#         所以最可靠的收窗＝停维持件 + adb reboot（无需 root 腿；w161 优雅收也等价，但踢框架后常派不动，故不用）。
set -u
export MSYS_NO_PATHCONV=1
export PATH="/c/adb/platform-tools:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 1
[ -f config.sh ] && . ./config.sh   # 可选：预设 ADB/DEV
ADB="${ADB:-adb}"; A(){ "$ADB" "$@"; }
ap(){ A shell "$1" 2>/dev/null | tr -d '\r'; }

echo "==== z6_off  收窗 ===="
echo "[1] 停维持件（避免收窗过程中又去抢装）"
ap "rm -f /data/local/tmp/b8_keep"
# 顺带停掉 watcher/keeper（有 root 才能杀，尽力）
ap "for p in \$(ps -A -o PID,ARGS 2>/dev/null | grep -a 'b8_keep.sh RUN' | grep -av grep | awk '{print \$1}'); do kill -9 \$p 2>/dev/null; done" >/dev/null 2>&1

MOD=$(ap "grep -c kernelsu /proc/modules"); MOD=${MOD:-0}
if [ "$MOD" = "1" ]; then
  echo "[2] adb reboot 干净收窗"
  A reboot
  for i in $(seq 1 45); do sleep 6; ST=$(ap "getprop sys.boot_completed"); [ "$ST" = "1" ] && break; done
else
  echo "[2] 当前已无模块(mod=0)，无需重启"
fi

echo "[3] 复核（应 mod=0 / Enforcing / boot=1 / 无 su·/dev/ksud）:"
ap "echo mod=\$(grep -c kernelsu /proc/modules) enf=\$(getenforce) boot=\$(getprop sys.boot_completed) su=\$(ls /product/bin/su 2>&1|head -1) kdev=\$(ls /dev/ksud 2>&1|head -1)"
echo "  done."
