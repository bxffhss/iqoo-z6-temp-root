#!/bin/bash
# w146_sancleanup.sh —— 只为一件事：把 ksud 实验留在 /data 与 /metadata 的残留清掉。
#   第 40 发那次收尾清理**没跑成**(w142_clean.out 根本没生成 ⇒ sushd 已到 1800s 时限)，
#   所以 /data/adb(ksud + modules/zygisk_lsposed) 与 /metadata/watchdog/ksu(modules.rc) 还在。
#   shell 删不掉(两个目录都是 root 0700)，只能 root 侧删 ⇒ 需要一次 punch。
#   ★不做任何实验，只 punch → 等 stage → 删 → 验证 → 重启。
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch)"; exit 2; }
export ANDROID_SERIAL=${ANDROID_SERIAL:-<DEVICE_SERIAL>}
A() { MSYS_NO_PATHCONV=1 adb shell "$1" 2>&1; }

echo "=== 1) 残留现状(shell 侧只能看到存不存在) ==="
A 'echo "enforce=$(getenforce) mod=$(grep -c kernelsu /proc/modules)"; ls -d /data/adb /metadata/watchdog/ksu 2>&1' | sed 's/^/  /'

echo "=== 2) push → reboot → punch → 等 stage ==="
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|uname -s =|\[x\]" | sed 's/^/  /'
MSYS_NO_PATHCONV=1 adb push kmod/w142_clean_adb.sh /data/local/tmp/w142_clean_adb.sh >/dev/null 2>&1
A 'chmod 755 /data/local/tmp/w142_clean_adb.sh; rm -f /data/local/tmp/w142_clean.out /data/local/tmp/ksu_stage.log' >/dev/null
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
sleep 45
I_KNOW=1 bash suw_apk/bootstrap.sh --punch > kmod/w146_punch.log 2>&1
grep -aq dispatched kmod/w146_punch.log || { grep -aE '\[x\]|负载' kmod/w146_punch.log | tail -3 | sed 's/^/  /'; echo "[x] punch 没派发"; exit 7; }
for i in $(seq 1 230); do
    sleep 5
    N=$(A 'grep -ac "判据④" /data/local/tmp/ksu_stage.log 2>/dev/null' | tr -dc '0-9')
    [ "${N:-0}" != "0" ] && { echo "  stage 到了 (t+$((i*5))s)"; break; }
    [ $((i % 20)) = 0 ] && echo "    还在等 post… t+$((i*5))s"
done
[ "${N:-0}" = "0" ] && { echo "[x] post 没跑 ⇒ 删不掉，保持现状并告知用户"; exit 5; }

echo "=== 3) root 侧删 ==="
A 'am force-stop com.suw.manager' >/dev/null; sleep 1
A 'am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd "@sushd:/data/local/tmp/w142_clean_adb.sh"' >/dev/null
sleep 40
A 'cat /data/local/tmp/w142_clean.out 2>&1 | tail -8' | sed 's/^/  /'

echo "=== 4) 验证 + 重启 ==="
A 'ls -d /data/adb /metadata/watchdog/ksu 2>&1' | sed 's/^/  /'
adb reboot >/dev/null 2>&1; echo "  已重启"
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
A 'echo "enforce=$(getenforce) mod=$(grep -c kernelsu /proc/modules)"; echo "最终残留:"; ls -d /data/adb /metadata/watchdog/ksu 2>&1' | sed 's/^/  /'
echo "=== 完 ==="
