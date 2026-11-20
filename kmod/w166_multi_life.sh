#!/bin/bash
# w166_multi_life.sh —— #55/#39 的对照实验：**只测一件事**——"往 .allowlist 里加条目"会不会让模块很快死。
#   为什么是这一发：今晚四跑里三跑在 insmod 后 1~2 分钟出事(两跑整机 PS_HOLD、一跑模块消失但 uptime 连续)，
#   而那三跑共同的新变量就是我为了"给官方 Manager 换 su 域"往名单里加的条目；
#   最后一跑(单条目、回归 7/7)模块活了 9 分钟到跑完 ⇒ 方向一致，但**没人采过"消失的那一刻"**。
#   ⇒ 这一发：多条目名单 + stage 的 `ksu_life_probe` 开关(抢救 pstore + setsid 采样器)，
#     PC 侧只观察不复读界面。**不做任何 UI 判据**，别把它当交付验证用。
#   ★跑完无论死活都把两个开关文件删掉，免得下一发被这个变量污染。
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch + reboot)"; exit 2; }
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
MGR=me.weishu.kernelsu
SUW=com.suw.manager
TGT=com.termux
CTL=/data/local/tmp/ksuctl88
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
WAITFOR() { local f=$1 n=$2 m=$3 i=0 g
    while [ "$i" -lt "$n" ]; do
        g=$(A "grep -acF '$m' $f 2>/dev/null" | tr -dc '0-9')
        case "$g" in ''|*[!0-9]) : ;; *) [ "$g" -ge 1 ] && { echo "      (等到 $f 的[$m])"; return 0; } ;; esac
        sleep 3; i=$((i+1))
    done; echo "      (等满 $((n*3))s 没有[$m])"; return 1; }
pk_uid() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }

echo "=== 1) 前置：uid/版本/工具 ==="
until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 5; done
TGTUID=$(pk_uid "$TGT"); SUWUID=$(pk_uid "$SUW")
for v in TGTUID SUWUID; do eval "X=\$$v"
    case "$X" in ''|*[!0-9]*) echo "[x] $v 不干净：[$X] ⇒ 停"; exit 3;; esac; done
echo "  suw=$SUWUID 第三方正对照=$TGTUID 官方 Manager=[$(A "pm list packages $MGR" | tr -d '\r')](这一发不需要它)"
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|\[x\]" | sed 's/^/  /'
adb push kmod/w166_life.sh kmod/w161_g2.sh /data/local/tmp/ >/dev/null 2>&1
adb push cm57/ksuctl88 /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w166_life.sh /data/local/tmp/w161_g2.sh $CTL" >/dev/null
LM=$(md5sum cm57/ksuctl88 | cut -c1-32); RM=$(A "md5sum $CTL" | cut -c1-32)
[ "$LM" = "$RM" ] || { echo "[x] 设备上 ksuctl88 不是这份(本机=$LM 设备=$RM) ⇒ 停"; exit 3; }
# ★两个开关：多条目名单 + 寿命采样(pstore 抢救 + setsid 采样器)
A "printf '%s\n' '$TGTUID:$TGT' > /data/local/tmp/ksu_two_profiles; touch /data/local/tmp/ksu_life_probe; echo 开关: \$(cat /data/local/tmp/ksu_two_profiles) \$(ls /data/local/tmp/ksu_life_probe)" | sed 's/^/  /'
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 5; done
sleep 40
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log /data/local/tmp/dmesg.live /data/local/tmp/w166_life.log" >/dev/null
for i in $(seq 1 40); do
    L1=$(A "cat /proc/loadavg" | cut -d. -f1)
    [ "${L1:-99}" -le 3 ] && { echo "  负载够低：load1=$L1 up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1)"; break; }
    [ $((i % 6)) = 0 ] && echo "    还在等: load1=$L1"
    sleep 15
done
I_KNOW=1 bash suw_apk/bootstrap.sh --punch >"$EV/w37_bootstrap.txt" 2>&1
echo "  bootstrap 退出码=$?"; tail -2 "$EV/w37_bootstrap.txt" | sed 's/^/    /'
for i in $(seq 1 20); do sleep 5; [ -n "$(A 'ls -l /data/local/tmp/punch.log 2>/dev/null')" ] && { echo "  pr 已起跑"; break; }; done

echo "=== 2) 等 stage 到 insmod(★这一发只看它什么时候没) ==="
SIX=0
for i in $(seq 1 140); do sleep 5
    SIX=$(A "grep -ac '名单/王座快照' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    [ "${SIX:-0}" != "0" ] && { echo "  insmod 快照已出 (t+$((i*5))s)"; break; }
    [ $((i % 10)) = 0 ] && echo "    还在等快照：up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1)"
done
A "grep -aE 'insmod rc|条目 [0-9]|wrote|allowlist:|granted\[|pstore 抢救|采样器' /data/local/tmp/ksu_stage.log | tail -12" | cut -c1-175 | sed 's/^/    /'
[ "${SIX:-0}" = "0" ] && { echo "[x] 没等到 insmod 快照 ⇒ 停(看 stage 自己怎么说)"; exit 5; }

echo "=== 3) 观察 8 分钟：每 20s 记一行(PC 侧与设备侧采样器各一份，互相印证) ==="
DIED=""
for k in $(seq 1 24); do
    ST=$(A 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) load1=$(cut -d" " -f1 /proc/loadavg)')
    echo "    [$((k*20))s] $ST"
    case "$ST" in *"mod=0 "*) DIED="PC 侧在第 $((k*20))s 看到 mod=0"; break ;; esac
    sleep 20
done
echo "=== 4) 采样器/落盘读数(机器若已复位，这些还在 /data) ==="
A "tail -14 /data/local/tmp/w166_life.log 2>&1" | cut -c1-140 | sed 's/^/    /'
A "grep -acF 'LIFE-DONE' /data/local/tmp/w166_life.log 2>/dev/null" | sed 's/^/    采样器收尾标记数=/'
A "ls -l /data/local/tmp/pstore_copied 2>&1 | head -8" | cut -c1-140 | sed 's/^/    /'
[ -n "$DIED" ] && echo "  ★$DIED ⇒ 与 §6.158 表里那三跑同型；等它回来再读 pstore_copied 与 life.log"
echo "=== 5) 删开关(别污染下一发) + 收尾 ==="
A 'rm -f /data/local/tmp/ksu_two_profiles /data/local/tmp/ksu_life_probe; ls /data/local/tmp/ | grep -aE "ksu_two_profiles|ksu_life_probe"; echo 开关已清'
echo "  现在状态：$(A 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce)')"
echo "  要收尾就：I_KNOW=1 bash kmod/w161_teardown.sh   (它会顺手跑 root 侧 /data/adb 清理)"
