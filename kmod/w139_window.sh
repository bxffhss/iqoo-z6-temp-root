#!/bin/bash
# w139_window.sh —— 活窗口内试"官方独立 ksud 能不能驱动模块"。
# 用法：I_KNOW=1 bash kmod/w139_window.sh
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch)"; exit 2; }
export ANDROID_SERIAL=${ANDROID_SERIAL:-<DEVICE_SERIAL>}
A() { MSYS_NO_PATHCONV=1 adb shell "$1" 2>&1; }     # ★调用方一律传单引号字符串，否则 $( ) 被本机展开
EV=kmod/w103_evidence; mkdir -p "$EV"
P=/data/local/tmp/w139_ksud.out

echo "=== -1) preflight ==="
PF=$(A 'echo PFOK-$(cat /proc/uptime | cut -d" " -f1)')
case "$PF" in *PFOK*) echo "  $PF";; *) echo "[x] adb 不通/多设备：$PF"; exit 6;; esac
A 'echo "suw=[$(pm list packages com.suw.manager)] mgr=[$(pm list packages me.weishu.kernelsu)] ksud=$(md5sum /data/local/tmp/ksud 2>&1 | cut -c1-32)"' | sed 's/^/  /'

echo "=== 1) push ko(rc60) → reboot → punch ==="
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|uname -s =|\[x\]" | sed 's/^/  /'
MSYS_NO_PATHCONV=1 adb push kmod/w139_ksud_probe.sh /data/local/tmp/w139_ksud_probe.sh >/dev/null 2>&1
A 'chmod 755 /data/local/tmp/w139_ksud_probe.sh'
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
sleep 45
A "rm -f /data/local/tmp/ksu_stage.log $P" >/dev/null
I_KNOW=1 bash suw_apk/bootstrap.sh --punch > kmod/w139_punch.log 2>&1
grep -aE 'slide=|dispatched|pr=|\[x\]' kmod/w139_punch.log | tail -5 | sed 's/^/  /'
grep -aq dispatched kmod/w139_punch.log || { echo "[x] punch 没派发(见 kmod/w139_punch.log)"; exit 7; }
for i in $(seq 1 230); do
    sleep 5
    N=$(A 'grep -ac "判据④" /data/local/tmp/ksu_stage.log 2>/dev/null' | tr -dc '0-9')
    [ "${N:-0}" != "0" ] && { echo "  到了 (t+$((i*5))s)"; break; }
    [ $((i % 20)) = 0 ] && echo "    还在等 post… t+$((i*5))s mod=$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)"
done
[ "${N:-0}" = "0" ] && { echo "[x] post 整 boot 没跑"; exit 5; }
A 'echo "mod=$(grep -c kernelsu /proc/modules) enforce=$(getenforce) suw=[$(pidof com.suw.manager)]"' | sed 's/^/  /'

echo "=== 2) root 侧跑 ksud 探针(每条子命令都套 timeout 25，最坏 ~200s) ==="
A 'am force-stop com.suw.manager' >/dev/null; sleep 1
A 'am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd "@sushd:/data/local/tmp/w139_ksud_probe.sh"' >/dev/null
for i in $(seq 1 40); do
    sleep 8
    [ "$(A 'test -f /data/local/tmp/w139_ksud.out && echo Y || echo N')" = "Y" ] && { echo "  回执文件已出现 (t+$((i*8))s)"; break; }
done
sleep 20
A "cat $P 2>&1" | sed 's/^/  /' | tee kmod/w139_ksud.out.txt >/dev/null
MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w139_ksud.out "$EV/w34_ksud.out" >/dev/null 2>&1 && echo "  存证 $EV/w34_ksud.out"
A 'dmesg | grep -aE "Crowning|is_manager|ksud|KSUBEAT SU" | tail -12' | cut -c1-150 | sed 's/^/  dmesg: /'
echo "=== 完 ==="
