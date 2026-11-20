#!/usr/bin/env bash
# w547_guard_watch.sh —— 等 `mod=1` 出现的**第一时间**把护栏反对照派进 root 通道（不等 go.sh 的腿序）。
#   为什么要单独有这个：第 41 发(10-23 11:09 boot)rc73 装载后我在 ~insmod+150s 才手敲派发，
#   而那一窗口的实际寿命只有 ≈60~210 秒 ⇒ 派发落在复位之后，`w543_kt.out` 根本没生成＝**没测到**。
#   ⇒ 节拍：每 2 秒读一次 /proc/modules(1 fork/次，这台机没有零 fork 的延时)，一见到 kernelsu 就派单。
#   证人：打印派发那一刻的 up／派发返回码／等产物出现的秒数／产物全文。绝不把"没产物"说成"测过了"。
set -u
cd "$(dirname "$0")/.." || exit 1
A() { MSYS_NO_PATHCONV=1 adb shell "$1" 2>&1 | tr -d '\r'; }
MOD=0
for i in $(seq 1 900); do
    M=$(A 'grep -c kernelsu /proc/modules' | tr -dc '0-9')
    [ "$M" = 1 ] && { MOD=1; break; }
    [ $((i % 15)) = 0 ] && echo "  等 mod=1…第 $i 次(load1=$(A 'cat /proc/loadavg' | cut -d' ' -f1))"
    sleep 2
done
if [ "$MOD" != 1 ]; then echo "[x] 等了 1800 秒仍没见到 mod=1 ⇒ 这一格＝没测到"; exit 7; fi
U=$(A 'cat /proc/uptime' | cut -d. -f1)
echo "  mod=1 见到于 up=$U  本机时刻=$(date +%H:%M:%S)"
A 'rm -f /data/local/tmp/w543_kt.out' >/dev/null
# 脚本件可能在 reboot/收尾里没了 ⇒ 每次开窗自己重新铺，并核两端 md5(例：Git Bash 谎报那一族)
LM=$(md5sum kmod/w543_kt.sh | cut -c1-32)
MSYS_NO_PATHCONV=1 adb push kmod/w543_kt.sh /data/local/tmp/w543_kt.sh >/dev/null 2>&1
A 'chmod 755 /data/local/tmp/w543_kt.sh' >/dev/null
RM=$(A 'md5sum /data/local/tmp/w543_kt.sh' | cut -c1-32)
[ "$LM" = "$RM" ] && echo "  腿件已铺并对回 md5=$LM" || { echo "  [x] 腿件两端 md5 不符(本机=$LM 设备=$RM)⇒ 不派发"; exit 8; }
# ★派发要**重试到产物出现**：root 通道(suw→@suwshd)是 stage 在 insmod 之后才起来的，
#   只发一次会像第 41 发那样落在"没人监听"或"已经复位"上＝白烧一发。
LANDED=0
for k in $(seq 1 30); do
    A 'am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd "@sushd:/data/local/tmp/w543_kt.sh"' >/dev/null
    sleep 5
    S=$(A 'wc -c < /data/local/tmp/w543_kt.out 2>/dev/null' | tr -dc '0-9')
    echo "  第 $k 次派发后：产物字节=${S:-0} up=$(A 'cat /proc/uptime' | cut -d. -f1) enf=$(A 'getenforce')"
    if [ -n "$S" ] && [ "$S" != 0 ]; then LANDED=1; break; fi
done
[ "$LANDED" = 1 ] || echo "  [x] 派发 30 次仍没有产物 ⇒ 这一格＝**没测到**(别当通过)"
echo "  ---- w543_kt.out 全文 ----"
A 'cat /data/local/tmp/w543_kt.out 2>&1'
echo "  ---- 同刻的三条独立读数 ----"
A 'echo "up=$(cat /proc/uptime | cut -d. -f1) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce)"'
A 'grep -ac KSUFDINST /data/local/tmp/dmesg.live 2>/dev/null | sed "s/^/dmesg.live 里 KSUFDINST 行数=/"'
A 'grep -ac "NULLFILES skip" /data/local/tmp/dmesg.live 2>/dev/null | sed "s/^/其中 NULLFILES skip 行数=/"'
A 'grep -a KSUFDINST /data/local/tmp/dmesg.live 2>/dev/null | tail -6 | cut -c1-140'
