#!/bin/bash
# w158_hold_window.sh —— 开一个窗口并**保持 14 分钟**，期间每 20 秒读一次内核侧的 granted，
#   让人在**官方 KernelSU Manager 的 UI** 上把 com.termux 加进名单；加上的那一刻起，
#   脚本自己替 Termux 敲 su 并取证。★这是"人出眼睛、机器出证据"的一发：
#   第五发的教训是 vivo 的前台化我隔着 adb 看不住(mCurrentFocus 恒 null + 重试里按 HOME
#   反而把 Manager 挤回桌面)，而 UI 上有什么按钮，坐在手机前的人一眼就知道。
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch + reboot)"; exit 2; }
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1; }
EV=kmod/w103_evidence; mkdir -p "$EV"
MGR=me.weishu.kernelsu
SUW=com.suw.manager
TGT=com.termux
shot() { adb exec-out screencap -p > "$EV/w32_$1.png" 2>/dev/null
         echo "      截图 w32_$1.png $(stat -c %s "$EV/w32_$1.png" 2>/dev/null) 字节"; }
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
WAITFOR() { local f=$1 n=$2 m=$3 i=0 g
    while [ "$i" -lt "$n" ]; do
        g=$(A "grep -acF '$m' $f 2>/dev/null" | tr -d '\r\n')
        case "$g" in ''|*[!0-9]) : ;; *) [ "$g" -ge 1 ] && { echo "      (等到 $f 的[$m])"; return 0; } ;; esac
        sleep 3; i=$((i+1))
    done; echo "      (等满 $((n*3))s 没有[$m])"; return 1; }
pk_uid() { A "pm list packages -U" | tr -d '\r' | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }

echo "=== 1) 前置与 uid 实况(纯数字形状闸，绝不带假 uid 往下走) ==="
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
TGTUID=$(pk_uid "$TGT"); MGRUID=$(pk_uid "$MGR"); SUWUID=$(pk_uid "$SUW")
echo "  Termux=$TGTUID  官方 Manager=$MGRUID  suw=$SUWUID"
for v in TGTUID MGRUID SUWUID; do
    eval "X=\$$v"
    case "$X" in ''|*[!0-9]*) echo "[x] $v 不干净：[$X] ⇒ 停"; exit 3;; esac
done

echo "=== 2) reboot → punch → 等本 boot 的 stage ==="
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
sleep 40
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log" >/dev/null
I_KNOW=1 bash suw_apk/bootstrap.sh --punch >"$EV/w32_bootstrap.txt" 2>&1
echo "  bootstrap 退出码=$?"; tail -4 "$EV/w32_bootstrap.txt" | sed 's/^/    /'
for i in $(seq 1 20); do sleep 5
    [ -n "$(A 'ls -l /data/local/tmp/punch.log 2>/dev/null')" ] && { echo "  pr 已起跑"; break; }
done
N=0
for i in $(seq 1 220); do sleep 5
    N=$(A "grep -ac '判据④' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    [ "${N:-0}" != "0" ] && { echo "  stage 到判据④ (t+$((i*5))s)"; break; }
done
[ "${N:-0}" = "0" ] && { echo "[x] post 整 boot 没跑 ⇒ 停"; exit 5; }

echo "=== 3) 把 su 挂出来(没有它 Termux 只能拿到 ENOENT，第五十九发已一手证过) ==="
adb push cm57/sustatic /data/local/tmp/sustatic >/dev/null 2>&1
adb push kmod/w135_fix.sh /data/local/tmp/w135_fix.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/sustatic /data/local/tmp/w135_fix.sh; rm -f /data/local/tmp/w135_fix.out" >/dev/null
fire "@sushd:/data/local/tmp/w135_fix.sh" 8
WAITFOR /data/local/tmp/w135_fix.out 40 "===== DONE"
A "grep -aE 'BIND_RC|SU_AT_TGT|HEALTH' /data/local/tmp/w135_fix.out | cut -c1-110" | sed 's/^/    /'

echo "=== 4) ★现在请你在手机上操作(内核侧每 20s 复读一次，看到 granted=1 我就自己往下走) ==="
echo "   ① 打开 **KernelSU**(官方那个) → 首页应显示[工作中 [越狱模式] 版本：32601-2]"
echo "   ② 底部 **超级用户** → 右上/右下的 **加号(添加应用)** → 选 **Termux** → 把 **Root 授权**开关打开"
echo "   ③ 什么都不用回我，脚本自己会看到 granted 翻成 1"
A "echo $TGTUID > /data/local/tmp/w157_tgt.uid" >/dev/null
adb push kmod/w157_g.sh /data/local/tmp/w157_g.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w157_g.sh" >/dev/null
GR=0
for k in $(seq 1 42); do
    A "rm -f /data/local/tmp/w157_g.out" >/dev/null
    fire "@sushd:/data/local/tmp/w157_g.sh" 5
    WAITFOR /data/local/tmp/w157_g.out 12 "=== DONE ===" >/dev/null
    L=$(A "grep -a UID_GRANTED_ROOT /data/local/tmp/w157_g.out 2>/dev/null" | tr -d '\r' | tail -1)
    echo "  [轮 $k] $L"
    case "$L" in *"granted=1"*) GR=1; echo "  ★名单里有了 ⇒ 继续，不需要你再动手"; break;; esac
    sleep 12
done
[ "$GR" = 1 ] || { echo "[x] 14 分钟里没等到 granted=1 ⇒ 这一格没证到(截图都在 $EV/w32_*)"; }

if [ "$GR" = 1 ]; then
    echo "=== 5) Termux 敲 su(绝对路径；这一次文件真在，且名单里有它) ==="
    A "am force-stop $TGT" >/dev/null; sleep 1
    A "am start -n $TGT/.app.TermuxActivity" >/dev/null 2>&1 || A "monkey -p $TGT 1" >/dev/null 2>&1
    sleep 12
    A "input text '/system/bin/su'"; A "input keyevent 66"; sleep 5
    A "input text 'id'; input keyevent 66"; sleep 8; shot termux_su
    echo "    ★看 w32_termux_su.png：期望 uid=0(root) gid=0(root) context=…"
    A "grep -aE 'KSUBEAT (SU0|X7|X8)' /data/local/tmp/dmesg.live 2>/dev/null | grep -a 'uid=$TGTUID' | tail -5" | cut -c1-150 | sed 's/^/    /'
    A "grep -aE \"KSUBEAT (SU0|X7|X8)\" /data/local/tmp/dmesg.live 2>/dev/null | grep -ac 'uid=$TGTUID'" | sed 's/^/    带 Termux uid 的脚印条数: /'
    echo "=== 5.5) 反向对照：官方 UI 里关掉之后必须又变回 granted=0(否则名单是假的) ==="
    echo "    (要关就现在关；不关也行，只是少一格负对照)"
    A "rm -f /data/local/tmp/w157_g.out" >/dev/null
    fire "@sushd:/data/local/tmp/w157_g.sh" 5
    WAITFOR /data/local/tmp/w157_g.out 12 "=== DONE ===" >/dev/null
    A "grep -a UID_GRANTED_ROOT /data/local/tmp/w157_g.out | tail -1" | sed 's/^/    当前: /'
fi

echo "=== 6) 收尾：root 侧先 umount 成功再删源 → reboot → 复核 ==="
adb push kmod/w135_off.sh /data/local/tmp/w135_off.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w135_off.sh; rm -f /data/local/tmp/w135_off.out" >/dev/null
fire "@sushd:/data/local/tmp/w135_off.sh" 8
WAITFOR /data/local/tmp/w135_off.out 40 "===== DONE"
A "grep -aE 'MOUNT_LEFT|SU_GONE|RM_DIRS_OK' /data/local/tmp/w135_off.out | cut -c1-110" | sed 's/^/    /'
A "rm -f /data/local/tmp/w157_g.sh /data/local/tmp/w157_g.out /data/local/tmp/w157_tgt.uid" >/dev/null
adb reboot
for i in $(seq 1 60); do sleep 5; [ -n "$(adb get-state 2>/dev/null | grep device)" ] && break; done
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = "1" ]; do sleep 10; done
sleep 20
A "echo 收尾复核: up=\$(cut -d' ' -f1 /proc/uptime) mod=\$(grep -c kernelsu /proc/modules) enf=\$(getenforce) 挂载=\$(grep -c pbin /proc/self/mountinfo) bin=\$(ls -A /product/bin | wc -l)" | sed 's/^/  /'
