#!/system/bin/sh
# w346_sx1_dev.sh —— 只读：rc68 的 SX1 到底有没有命中 + Manager 现在的 seccomp 状态
OUT=/data/local/tmp/w346_sx1.out
exec > "$OUT" 2>&1
echo "[$(date +%H:%M:%S)] uid=$(id -u) enf=$(getenforce) up=$(cut -d' ' -f1 /proc/uptime)"
echo "--- ① SX1 命中行(期望有) ---"
dmesg 2>/dev/null | grep -a 'SX1 selfexec' | tail -6
echo "SX1_COUNT=$(dmesg 2>/dev/null | grep -a -c 'SX1 selfexec')"
echo "--- ② SD1 拒绝行(Manager 若没在名单里，这里会有一堆而 SX1=0) ---"
echo "SD1_COUNT=$(dmesg 2>/dev/null | grep -a -c 'KSUBEAT SD1 decline')"
dmesg 2>/dev/null | grep -a 'SD1 decline' | grep -a 'uid=10104' | tail -3
echo "--- ③ 改道有没有碰过 libksud(应当没有：改道只匹配 /system/bin/su) ---"
dmesg 2>/dev/null | grep -a 'libksud' | tail -4
echo "--- ④ Manager 进程状态(期望 Seccomp 命中后=0) ---"
for P in $(pidof me.weishu.kernelsu); do
    echo "pid=$P"; grep -E '^(Uid|NoNewPrivs|Seccomp|CapEff)' /proc/$P/status 2>&1 | tr '\n' ' '; echo
done
echo "--- ⑤ ksud 动词有没有被调 ---"
logcat -d -s KernelSU 2>/dev/null | grep -a 'ksud::cli' | tail -4
echo "--- ⑥ 名单里现在有谁 ---"
ls -l /data/adb/ksu/.allowlist 2>&1 | head -2
[ -f /data/adb/ksu/.allowlist ] && od -c /data/adb/ksu/.allowlist 2>/dev/null | head -6
echo "[===== DONE =====]"
