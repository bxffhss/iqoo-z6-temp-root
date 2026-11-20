#!/system/bin/sh
# w844_syscall_leg.sh —— 只为一件事：把"libksud.so 死于 SIGSYS"再往下钉一层——**是哪个 syscall 被 seccomp 打死**。
#   #193 到这里只证明了信号号那一层(31/SYS_SECCOMP)，而记忆里那条"§6.419 把 reboot(142) 降回未证"要的是
#   syscall 号＋栈顶，所以这里逐支取：`signal` 行、`>>> pkg <<<` 行、寄存器/code 行、前 4 帧。全程只读。
OUT=/data/local/tmp/w844_syscall.out
PATH=/system/bin:/system/xbin:/product/bin:/vendor/bin
export PATH
: > $OUT 2>/dev/null
exec > $OUT 2>&1
chmod 666 $OUT 2>/dev/null

echo "== w844 起 $(date '+%F %T') up=$(cut -d' ' -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) =="
echo
echo "== A) 本 boot 里每支 SYSTEM_TOMBSTONE 的『信号＋syscall＋栈顶一帧』 =="
for F in $(ls -t /data/system/dropbox 2>/dev/null | grep -a '^SYSTEM_TOMBSTONE@.*\.txt\.gz$' | head -8); do
    echo "-- $F --"
    gzip -dc "/data/system/dropbox/$F" 2>/dev/null | \
        grep -aE 'Timestamp|^pid:|^uid:|signal [0-9]+|^>>> |Code: | Cause:|si_code|#0[0-3] pc' | head -12
done

echo
echo "== B) 最新两支 tombstone 文件本体(不是 dropbox 副本)的头 30 行 =="
for T in $(ls -t /data/tombstones 2>/dev/null | grep -aE '^tombstone_[0-9]+$' | head -2); do
    echo "---- /data/tombstones/$T ----"
    head -30 "/data/tombstones/$T" 2>&1
done

echo
echo "== C) ANR 那两支的完整 Subject＋Reason＋CPU 段首行(卡死那一格的实体) =="
for F in $(ls -t /data/system/dropbox 2>/dev/null | grep -a '^data_app_anr@.*\.txt\.gz$' | head -3); do
    echo "-- $F --"
    gzip -dc "/data/system/dropbox/$F" 2>/dev/null | grep -aE '^(Subject|Package|Reason|Timestamp|Notes|CPU usage|is not responding|Waited)' | head -8
done

echo
echo "== D) 这窗里 suw/Manager/守护们的存活与 seccomp 现值(对照用) =="
for P in me.weishu.kernelsu com.termux com.suw.manager; do
    echo "  pidof $P = $(pidof $P)"
done
echo "  驱动 fd 总数(逐 pid 求和)=$(for P in $(pidof me.weishu.kernelsu com.termux); do ls -l /proc/$P/fd 2>/dev/null | grep -ac ksu_driver; done | awk '{s+=$1} END{print s+0}')"
echo
echo "  KILLSOFT=$(grep -ac 'KILLSOFT' /data/local/tmp/dmesg2.log 2>/dev/null)  已跳过=$(grep -ac 'KILLGUARD: 已跳过' /data/local/tmp/dmesg2.log 2>/dev/null)"
echo "  窗龄：insmod up=20918.49 ⇒ 现在 up=$(cut -d' ' -f1 /proc/uptime) 差=$(( $(cut -d' ' -f1 /proc/uptime | cut -d. -f1) - 20918 )) 秒"
echo "  root 腿终点 $(date '+%F %T')"
chmod 666 $OUT 2>/dev/null
