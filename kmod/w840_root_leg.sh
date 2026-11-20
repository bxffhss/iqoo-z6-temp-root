#!/system/bin/sh
# w840_root_leg.sh —— **root 侧**的一条腿（由 app 腿用 su 拉起），只做只读事，产出并 chmod 666。
#   要拿的三格(#193)：①Manager 有没有驱动 fd(fd_ksu)；②它的 SigPnd/Seccomp 现值；
#   ③这台机上"谁死于哪个信号"的**实名行**：dropbox 目录里的条目名＋tombstone 列表(不靠命中词推断)。
OUT=/data/local/tmp/w840_root.out
# ★root 壳的 PATH 不由我控(记忆里那条：root 壳里没有 getenforce/umount)⇒ 进门第一件事自己定一条，
#   这样下面所有裸写的 id/grep/ls/pidof/pm 才有确定形状(而不是静默"command not found"把判据吞掉)。
PATH=/system/bin:/system/xbin:/product/bin:/apex/com.android.runtime/bin:/vendor/bin
export PATH
: > $OUT 2>/dev/null
exec > $OUT 2>&1
chmod 666 $OUT 2>/dev/null

echo "== root 腿起点 $(date '+%F %T') =="
id
echo "-- 我的 seccomp(root 应当 Seccomp=0，这是记忆里那条'root 域完全通'的复证) --"
grep -aE '^(Seccomp|CapEff|Uid)' /proc/self/status

echo
echo "== ①/② Manager 各 pid：状态＋fd_ksu 计数 ====="
for P in $(pidof me.weishu.kernelsu); do
    echo "-- pid=$P comm=$(cat /proc/$P/comm 2>/dev/null) --"
    grep -aE '^(State|Uid|Gid|SigPnd|ShdPnd|SigBlk|Seccomp|Threads):' /proc/$P/status 2>&1
    echo "  fd 总数=$(ls /proc/$P/fd 2>/dev/null | wc -l)"
    echo "  fd_ksu=$(ls -l /proc/$P/fd 2>/dev/null | grep -ac ksu_driver)"
    ls -l /proc/$P/fd 2>/dev/null | grep -a 'ksu_driver\|anon_inode' | head -4
done

echo
echo "== ②b 被授权 app(10667) 自己的领头：fd 与 Seccomp =="
for P in $(pidof com.termux); do
    echo "-- pid=$P comm=$(cat /proc/$P/comm 2>/dev/null) --"
    grep -aE '^(State|Uid|SigPnd|Seccomp):' /proc/$P/status 2>&1
    echo "  fd_ksu=$(ls -l /proc/$P/fd 2>/dev/null | grep -ac ksu_driver)"
done

echo
echo "== ③ 谁死于哪个号：dropbox 实名条目(最近 15 条) =="
ls -t /data/system/dropbox 2>&1 | head -15
echo "-- 其中含 kernel/系统崩溃类的 --"
ls /data/system/dropbox 2>/dev/null | grep -a 'system_server\|kernel\|tombstone' | head -5
echo "-- tombstone 目录最近 6 支 --"
ls -t /data/tombstones 2>&1 | head -6

echo
echo "== ④ 活表读数(内核侧现值，不是打印) =="
/data/local/tmp/ksuctl88 info 2>&1 | tail -2

echo
echo "== ⑤ 名单里那条到底是谁(取 uid→包名，走 packages 现查) =="
pm list packages -U 2>/dev/null | grep -a ':10667$' | head -3

echo
echo "== 我们那把挡枪的**行为**证人(装载期自报不算) =="
echo "  KILLSOFT 行数=$(grep -ac 'KILLSOFT' /data/local/tmp/dmesg2.log 2>/dev/null)"
grep -a 'KILLSOFT' /data/local/tmp/dmesg2.log 2>/dev/null | tail -2
echo "  KILLGUARD: 已跳过 行数=$(grep -ac 'KILLGUARD: 已跳过' /data/local/tmp/dmesg2.log 2>/dev/null)(期望 0：那枚探针不注册)"
echo "  fired 末值=$(grep -ao 'fired#[0-9]*' /data/local/tmp/dmesg2.log 2>/dev/null | tail -1)"
echo "  出生安装 total/cap：$(grep -ao 'total=[0-9]*' /data/local/tmp/dmesg2.log 2>/dev/null | tail -1) cap行=$(grep -ac 'KSUBIRTH cap' /data/local/tmp/dmesg2.log 2>/dev/null)"

echo
echo "== root 腿终点 $(date '+%F %T') =="
chmod 666 $OUT 2>/dev/null
