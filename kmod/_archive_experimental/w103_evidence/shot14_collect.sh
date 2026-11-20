#!/usr/bin/env bash
# shot14 取证链（稳定路线 rc80+0x0）：等 go.sh 第 8 步收尾后，做 ioctl 正负对照 + dmesg 0x0 形状 + 存活复检。
# 不改动任何已登记件；显式推 asuid_grant + w1186_asuid.sh（go.sh 不推这两件）。
set -u
cd "$(dirname "$0")/../.." || exit 1
A="/c/adb/platform-tools/adb.exe -s <DEVICE_SERIAL>"
L="kmod/w103_evidence/go_run_rc80_shot14.log"
O="kmod/w103_evidence/shot14_evidence.txt"
: > "$O"

echo "=== shot14 取证链起 $(date '+%F %T') ===" >> "$O"

# 0) prep：推 ioctl 测试件（go.sh 不推，必须显式推）
$A push kmod/asuid_grant /data/local/tmp/asuid_grant >/dev/null 2>&1
$A push kmod/w1186_asuid.sh /data/local/tmp/w1186_asuid.sh >/dev/null 2>&1
$A shell 'chmod 755 /data/local/tmp/asuid_grant /data/local/tmp/w1186_asuid.sh; ls -l /data/local/tmp/asuid_grant /data/local/tmp/w1186_asuid.sh' >> "$O" 2>&1

# 1) 等 go.sh 走到第 8 步（窗口开 + 交付默认自愈），避免与它的 root 腿抢 @sushd 通道
GOT=0
for i in $(seq 1 600); do
    grep -aq '=== 8) 交付默认自愈' "$L" 2>/dev/null && { GOT=1; break; }
    sleep 5
done
echo "go_sh_reached_step8=$GOT waited=$((i*5))s at $(date '+%F %T')" >> "$O"
sleep 5

# 2) 设备侧现读（存活 / 形状）
echo "--- device now ---" >> "$O"
$A shell 'echo -n "up="; cut -d" " -f1 /proc/uptime; echo -n "mod="; grep -c kernelsu /proc/modules; echo -n "enf="; getenforce; echo "ksud=[$(ls -l /dev/ksud 2>&1 | tr -s " ")]"; echo "bootreason=[$(getprop ro.boot.bootreason)]"' >> "$O" 2>&1

# 3) ioctl 正负对照（POS 10342 / NEG 10667），经 @sushd(root) 派单 w1186_asuid.sh
echo "--- dispatch w1186_asuid.sh via @sushd ---" >> "$O"
$A shell 'rm -f /data/local/tmp/w1186_asuid.out; am force-stop com.suw.manager' >/dev/null 2>&1
sleep 1
$A shell 'am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd "@sushd:/data/local/tmp/w1186_asuid.sh"' >> "$O" 2>&1
LEG=0
for j in $(seq 1 60); do
    N=$($A shell 'grep -acF "===== DONE =====" /data/local/tmp/w1186_asuid.out 2>/dev/null' | tr -dc '0-9')
    [ "${N:-0}" -ge 1 ] && { LEG=1; break; }
    sleep 3
done
echo "ioctl_done=$LEG waited=$((j*3))s" >> "$O"
echo "--- w1186_asuid.out 全文 ---" >> "$O"
$A shell 'cat /data/local/tmp/w1186_asuid.out 2>&1' >> "$O" 2>&1

# 4) dmesg 0x0 形状（BN=0、无 syscall_dispatcher、panic/Oops/Call trace=0）
echo "--- dmesg 计数(0x0 形状) ---" >> "$O"
$A pull /data/local/tmp/dmesg.live kmod/w103_evidence/shot14_dmesg.live >/dev/null 2>&1
D=kmod/w103_evidence/shot14_dmesg.live
if [ -f "$D" ]; then
    echo "bytes=$(wc -c < "$D") lines=$(wc -l < "$D")" >> "$O"
    for k in 'KSUBEAT BN' 'KSUBEAT B dispatcher' 'ksu_syscall_dispatcher:' 'callbacks suppressed' 'KernelSU' 'panic' 'Oops' 'Call trace'; do
        echo "  $k = $(grep -ac "$k" "$D" 2>/dev/null)" >> "$O"
    done
else
    echo "dmesg.live 未拉到" >> "$O"
fi

# 5) 存活复检（确认窗口持续、未崩）
echo "--- survival recheck ---" >> "$O"
$A shell 'echo -n "up_recheck="; cut -d" " -f1 /proc/uptime; echo -n "mod_recheck="; grep -c kernelsu /proc/modules; echo -n "enf_recheck="; getenforce; echo "bootreason_recheck=[$(getprop ro.boot.bootreason)]"' >> "$O" 2>&1

echo "=== shot14 取证链止 $(date '+%F %T') ===" >> "$O"
echo DONE_COLLECT
