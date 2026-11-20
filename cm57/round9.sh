#!/bin/bash
# round9.sh — "manager app 的 UI 端到端"取证轮
#   链(拿 root 窗口) → 窗口里只装 su 层+给 app 授权(不拆) → **窗口外**用 uid2000 拉起 app、
#   点它的刷新按钮、screencap 回主机看真实渲染 → 收尾 reboot
# 为什么 UI 必须放窗口外: 窗口里 root 进程 `input`/`screencap` 报 "Can't find service: input" 并段错误
#   (与"root 会话里 am 找不到 activity 服务"同类), 而 uid2000 的 adb shell 这两个都好使。
set -u
cd "/g/项目/Windows管理/usb/临时root" || exit 1
DEV=<DEVICE_SERIAL>
ADB="C:/adb/platform-tools/adb.exe"
A() { MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$DEV" "$@"; }
CL="J:/Users/Administrator/AppData/Local/Android/Sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android35-clang.cmd"
TAG=$(date +%m%d_%H%M)
NOREBOOT=${NOREBOOT:-0}
o=""

wait_load() {
  for i in $(seq 1 30); do
    l=$(A shell "cat /proc/loadavg" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
    ip=${l%%.*}; [ -n "$ip" ] || ip=9
    echo "[9] load1=$l (门槛 <6)"
    [ "$ip" -lt 6 ] && return 0
    sleep 15
  done
  return 1
}

echo "[9] ===== 第 1 步: 打链 + 装 su 层 ===== $(date +%H:%M:%S)"
if [ "$NOREBOOT" = 1 ] && [ "$(A shell 'uname -s' 2>/dev/null | tr -d '\r')" = "Linux" ] \
   && [ "$(A shell 'getenforce' 2>/dev/null | tr -d '\r')" = "Enforcing" ]; then
  echo "[9] 跳过 reboot(当前 boot 干净)"; o=Enforcing
else
  A reboot || exit 1
  A wait-for-device || exit 1
  for i in $(seq 1 40); do
    o=$(A shell "getenforce" 2>/dev/null | tr -d '\r')
    case "$o" in *Enforcing*|*Permissive*) break ;; esac
    sleep 5
  done
fi
echo "[9] shell 可用: $o"
wait_load || { echo "[9] 负载不落定"; exit 2; }
python cm57/solve_only.py 30 > cm57/round9_${TAG}_solve.log 2>&1
S=$(grep -a 'SOLVE_ONLY_RESULT' cm57/round9_${TAG}_solve.log | awk '{print $2}')
echo "[9] slide=$S"; { [ -n "$S" ] && [ "$S" != NONE ]; } || exit 2
wait_load || { echo "[9] 采样后负载没回落"; exit 2; }
[ "$(A shell 'uname -s' | tr -d '\r')" = "Linux" ] || { echo "[9] boot 不干净"; exit 2; }

A push cm57/prbin /data/local/tmp/pr > /dev/null || exit 1
A push cm57/sudbin /data/local/tmp/sudbin > /dev/null || exit 1
A push cm57/asuidbin /data/local/tmp/asuid > /dev/null || exit 1
A push cm57/su_layer_install.sh /data/local/tmp/su_layer_install.sh > /dev/null || exit 1
A shell "chmod 755 /data/local/tmp/pr /data/local/tmp/sudbin /data/local/tmp/asuid /data/local/tmp/su_layer_install.sh; rm -f /data/local/tmp/pr.log /data/local/tmp/su_layer.log /data/local/tmp/su.audit"

printf 'sh /data/local/tmp/su_layer_install.sh; exit\n' | \
  A shell -tt "cd /data/local/tmp && ./pr $S hammer hijack shape2 sen victim ishell ph2=0 ncopy5 shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 kids" \
  > cm57/round9_${TAG}_run.log 2>&1
echo "[9] ishell rc=$?"
sleep 3
A shell "cat /data/local/tmp/su_layer.log" > cm57/round9_${TAG}_layer.log 2>&1
grep -a 'LAYER_READY' cm57/round9_${TAG}_layer.log | tr -d '\r' || { echo "[9] 没装成 su 层, 停"; exit 3; }

echo "[9] ===== 第 2 步: 窗口外(uid2000)做 UI 取证 ====="
# 两条必须: ① 先唤醒+解屏(息屏时 screencap 得到的是全黑图, 白拍);
#          ② 二进制回读只能用 adb pull / exec-out, **不能** `adb shell cat > x.png`(pty 会做行转换, PNG 直接坏掉)
A shell 'input keyevent KEYCODE_WAKEUP; sleep 1; wm dismiss-keyguard; input keyevent KEYCODE_WAKEUP' >/dev/null 2>&1
sleep 2
A shell 'dumpsys power | grep -m1 "mWakefulness="; pidof sudbin; ls -l /product/bin/su' 2>&1 | tr -d '\r'
A shell 'am start -n com.suw.manager/.MainActivity' 2>&1 | tr -d '\r' | tail -2
sleep 7
A shell 'screencap -p /data/local/tmp/ui_before.png; echo cap_rc=$?' 2>&1 | tr -d '\r' | tail -1
A shell 'input tap 540 959' 2>&1 | tr -d '\r'
sleep 4
A shell 'screencap -p /data/local/tmp/ui_after.png; echo cap_rc=$?' 2>&1 | tr -d '\r' | tail -1
A pull /data/local/tmp/ui_before.png cm57/round9_${TAG}_ui_before.png >/dev/null 2>&1
A pull /data/local/tmp/ui_after.png  cm57/round9_${TAG}_ui_after.png  >/dev/null 2>&1
ls -l cm57/round9_${TAG}_ui_*.png
A shell 'logcat -d -t 300 | grep -iE "suw.manager|AndroidRuntime|FATAL" | tail -8' 2>&1 | tr -d '\r'
A shell 'cat /data/local/tmp/su.audit | tail -12' > cm57/round9_${TAG}_audit.log 2>&1
echo "[9] 账本尾部:"; tail -12 cm57/round9_${TAG}_audit.log | tr -d '\r'
echo "[9] 完成; 设备仍留着 su 层(等我看截图), 收尾请跑 cm57/round9_cleanup.sh"
