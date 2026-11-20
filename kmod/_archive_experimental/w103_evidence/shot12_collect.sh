#!/usr/bin/env bash
# shot12 取证链：等 go.sh 第 8 步收尾后，连贯做完「形状读数 + ioctl 正负对照 + dmesg」。
# 不新增/不改动任何已登记件；只读设备 + 派现成的 w1186_asuid.sh。
set -u
cd "$(dirname "$0")/../.." || exit 1
A="/c/adb/platform-tools/adb.exe -s <DEVICE_SERIAL>"
L="kmod/w103_evidence/go_run_rc80_shot12.log"
O="kmod/w103_evidence/shot12_evidence.txt"
: > "$O"

echo "=== shot12 取证链起 $(date '+%F %T') ===" >> "$O"

# 1) 等 go.sh 走到第 8 步（收尾），避免与它的第 4~7 步 root 腿抢 @sushd 通道
GOT=0
for i in $(seq 1 600); do
    grep -aq '=== 8) 交付默认自愈' "$L" 2>/dev/null && { GOT=1; break; }
    sleep 5
done
echo "go_sh_reached_step8=$GOT waited=$((i*5))s at $(date '+%F %T')" >> "$O"
sleep 5

# 2) 设备侧现读（形状判据 1/2）
echo "--- device now (up/mod/enf/bootreason/ksud/uids) ---" >> "$O"
$A shell 'echo -n "up="; cut -d" " -f1 /proc/uptime; echo -n "mod="; grep -c kernelsu /proc/modules; echo -n "enf="; getenforce; echo -n "bootreason="; getprop ro.boot.bootreason; echo "ksud=[$(ls -l /dev/ksud 2>&1)]"; echo "suw=[$(pm list packages -U | grep com.suw.manager)]"; echo "termux=[$(pm list packages -U | grep com.termux)]"' >> "$O" 2>&1

# 3) ioctl 正负对照：派现成的 w1186_asuid.sh（10342 名单内 / 10667 名单外）
echo "--- dispatch w1186_asuid.sh via @sushd ---" >> "$O"
$A shell 'rm -f /data/local/tmp/w1186_asuid.out; chmod 755 /data/local/tmp/w1186_asuid.sh /data/local/tmp/asuid_grant' >> "$O" 2>&1
$A shell 'am force-stop com.suw.manager' >/dev/null 2>&1
sleep 1
$A shell 'am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd "@sushd:/data/local/tmp/w1186_asuid.sh"' >> "$O" 2>&1
LEG=0
for j in $(seq 1 40); do
    N=$($A shell 'grep -acF "===== DONE =====" /data/local/tmp/w1186_asuid.out 2>/dev/null' | tr -dc '0-9')
    [ "${N:-0}" -ge 1 ] && { LEG=1; break; }
    sleep 3
done
echo "leg_done=$LEG waited=$((j*3))s" >> "$O"
echo "--- w1186_asuid.out 全文(ioctl 正负对照) ---" >> "$O"
$A shell 'cat /data/local/tmp/w1186_asuid.out 2>&1' >> "$O" 2>&1

# 4) dmesg：BN=0 的形状判据，配同通道「会非 0」对照
echo "--- dmesg 计数 ---" >> "$O"
$A pull /data/local/tmp/dmesg.live kmod/w103_evidence/shot12_dmesg.live >/dev/null 2>&1
$A shell 'dmesg 2>/dev/null | grep -ac "KSUBEAT BN"' >> "$O" 2>&1
echo "--- dmesg.live 本地计数 ---" >> "$O"
D=kmod/w103_evidence/shot12_dmesg.live
if [ -f "$D" ]; then
    echo "BN=$(grep -ac 'KSUBEAT BN' "$D" 2>/dev/null) suppressed_lines=$(grep -ac 'callbacks suppressed' "$D" 2>/dev/null) bytes=$(wc -c < "$D")" >> "$O"
else
    echo "dmesg.live 未拉到" >> "$O"
fi
echo "--- 同通道对照：第 11 发 shot11_dmesg2.log ---" >> "$O"
S=kmod/w103_evidence/shot11_dmesg2.log
if [ -f "$S" ]; then
    echo "shot11_BN=$(grep -ac 'KSUBEAT BN dispatcher' "$S" 2>/dev/null) shot11_suppressed=$(grep -ac 'callbacks suppressed' "$S" 2>/dev/null)" >> "$O"
else
    echo "shot11_dmesg2.log 不在" >> "$O"
fi

# 5) #55 设备侧采样时间轴
$A pull /data/local/tmp/w184_sample.out kmod/w103_evidence/shot12_w184_sample.out >/dev/null 2>&1
echo "--- w184_sample.out(本机副本)行数=$(wc -l < kmod/w103_evidence/shot12_w184_sample.out 2>/dev/null) ---" >> "$O"
tail -5 kmod/w103_evidence/shot12_w184_sample.out >> "$O" 2>&1

echo "=== shot12 取证链止 $(date '+%F %T') ===" >> "$O"
echo DONE_COLLECT
