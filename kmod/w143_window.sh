#!/bin/bash
# w143_window.sh —— 一个窗口内问完："模块到底能不能挂上"。
#   第 37 发已证 ksud 与我们 ko 的传输口通、模块能装能合并、模块级 sepolicy apply 不炸；
#   只剩 magic mount 那一格。这一发用"post-fs-data 跑第二遍"+"命名空间 id"把两种假设分开。
# 用法：I_KNOW=1 bash kmod/w143_window.sh
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch)"; exit 2; }
export ANDROID_SERIAL=${ANDROID_SERIAL:-<DEVICE_SERIAL>}
A() { MSYS_NO_PATHCONV=1 adb shell "$1" 2>&1; }     # ★一律传单引号，否则 $( ) 被本机展开
EV=kmod/w103_evidence; mkdir -p "$EV"
NEED=9cc94ff59388b09dd6d4097d25a1f83b

fire() {   # fire <设备侧脚本> <回执文件> <等待秒>
    A "rm -f $2" >/dev/null
    A 'am force-stop com.suw.manager' >/dev/null; sleep 1
    A "am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"@sushd:$1\"" >/dev/null
    sleep "$3"
    echo "----- $2 -----"
    A "cat $2 2>&1" | sed 's/^/  /'
}

echo "=== -1) preflight ==="
PF=$(A 'echo PFOK-$(cat /proc/uptime | cut -d" " -f1)')
case "$PF" in *PFOK*) echo "  $PF";; *) echo "[x] adb 不通：$PF"; exit 6;; esac

echo "=== 1) push ko(rc60) → reboot → punch ==="
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|uname -s =|\[x\]" | sed 's/^/  /'
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
sleep 45
# ★push_ksu.sh 会把我们自己的 shim 推成 /data/local/tmp/ksud ⇒ 官方那份必须用别的名字
MSYS_NO_PATHCONV=1 adb push kmod/ksud_official /data/local/tmp/ksud_official >/dev/null 2>&1
MSYS_NO_PATHCONV=1 adb push kmod/w143a_install.sh /data/local/tmp/w143a_install.sh >/dev/null 2>&1
MSYS_NO_PATHCONV=1 adb push kmod/w143b_mount.sh /data/local/tmp/w143b_mount.sh >/dev/null 2>&1
MSYS_NO_PATHCONV=1 adb push kmod/w142_clean_adb.sh /data/local/tmp/w142_clean_adb.sh >/dev/null 2>&1
MSYS_NO_PATHCONV=1 adb push "C:/Users/Administrator/Downloads/z5dl/x/z5_share/files/LSPosed-2.2.0.zip" /sdcard/Download/LSPosed-2.2.0.zip >/dev/null 2>&1
A 'chmod 755 /data/local/tmp/ksud_official /data/local/tmp/w143a_install.sh /data/local/tmp/w143b_mount.sh; rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/w143a.out /data/local/tmp/w143b.out' >/dev/null
echo "  工件: ksud=$(A 'md5sum /data/local/tmp/ksud_official | cut -c1-32')  zip=$(A 'stat -c %s /sdcard/Download/LSPosed-2.2.0.zip')"
[ "$(A 'md5sum /data/local/tmp/ksud_official | cut -c1-32')" = "$NEED" ] || { echo "[x] 官方 ksud 没推对"; exit 8; }
I_KNOW=1 bash suw_apk/bootstrap.sh --punch > kmod/w143_punch.log 2>&1
grep -aE 'slide=|dispatched|\[x\]' kmod/w143_punch.log | tail -4 | sed 's/^/  /'
grep -aq dispatched kmod/w143_punch.log || { echo "[x] punch 没派发"; exit 7; }
for i in $(seq 1 230); do
    sleep 5
    N=$(A 'grep -ac "判据④" /data/local/tmp/ksu_stage.log 2>/dev/null' | tr -dc '0-9')
    [ "${N:-0}" != "0" ] && { echo "  post 到了 (t+$((i*5))s)"; break; }
    [ $((i % 20)) = 0 ] && echo "    还在等 post… t+$((i*5))s mod=$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)"
done
[ "${N:-0}" = "0" ] && { echo "[x] post 整 boot 没跑"; exit 5; }
A 'echo "mod=$(grep -c kernelsu /proc/modules) enforce=$(getenforce) suw=[$(pidof com.suw.manager)] sushd=[$(pidof ksuctl)]"' | sed 's/^/  /'

echo "=== 2) 投递 A：装模块 ==="
fire /data/local/tmp/w143a_install.sh /data/local/tmp/w143a.out 75
echo "=== 3) 投递 B：post-fs-data 两遍 + 命名空间 ==="
fire /data/local/tmp/w143b_mount.sh /data/local/tmp/w143b.out 95

echo "=== 4) 收尾：清 /data/adb(跨重启留存) ==="
fire /data/local/tmp/w142_clean_adb.sh /data/local/tmp/w142_clean.out 35
for f in w143a.out w143b.out w143b_p1.txt w143b_p2.txt w143b_svc.txt; do
    MSYS_NO_PATHCONV=1 adb pull "/data/local/tmp/$f" "$EV/w38_$f" >/dev/null 2>&1 && echo "  存证 w38_$f"
done
echo "=== 完(看完结果再 reboot) ==="
