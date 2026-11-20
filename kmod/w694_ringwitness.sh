#!/system/bin/sh
# w694_ringwitness.sh —— 去**装载期那份全量件**里找 KSUBIRTH/KSUFDINST，并且先把覆盖区间打出来。
#   为什么要有这条(一手＝同发上一次读数)：`dmesg` 此刻只覆盖 up≈960~1175，而 insmod 在 up=728、
#   RACE 抢装在 up≈745 ⇒ 在活环里数到 0 是**覆盖不到**，不是没打印(记忆「计数=0 不是否据」那条)。
#   候选证人三件：/data/local/tmp/dmesg.live(stage 起的 kmsg 跟随器，装载期就在读)、
#   /data/local/tmp/dmesg2.log(常驻整环快照)、/data/local/tmp/dmesg.live.prev_*(上一发留的)。
#   ★每件都打印：字节数＋首末行时间戳(＝覆盖区间)＋命中数；覆盖区间不含 up=728 的那件**不许**拿来判"没打印"。
PATH=/system/bin:/system/xbin:/product/bin:/vendor/bin:$PATH
export PATH
L=/data/local/tmp/w694_ringwitness.out
{
    echo "=== W694 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) ==="
    for F in /data/local/tmp/dmesg.live /data/local/tmp/dmesg2.log /data/local/tmp/dmesg.live.prev_*; do
        [ -f "$F" ] || { echo "--- [$F] 不存在 ---"; continue; }
        echo "--- [$F] $(ls -l $F | cut -c1-58) 字节=$(wc -c < $F) 行数=$(grep -ac . $F)"
        echo "    覆盖：首行=[$(head -1 $F | cut -c1-58)]"
        echo "          末行=[$(tail -1 $F | cut -c1-58)]"
        echo "    命中：KSUBIRTH=$(grep -ac KSUBIRTH $F)  seen Manager=$(grep -ac 'seen Manager' $F)  queued self fd=$(grep -ac 'queued self fd' $F)  kzalloc failed=$(grep -ac 'kzalloc(ATOMIC) failed' $F)  task_work_add=$(grep -ac 'task_work_add pid' $F)"
        echo "          => fd=$(grep -ac '=> fd=' $F)  NULLFILES skip=$(grep -ac 'NULLFILES skip' $F)  KSUFDINST 总=$(grep -ac KSUFDINST $F)  dupskip 行=$(grep -ac 'KSUBIRTH dupskip' $F)  childskip 行=$(grep -ac 'KSUBIRTH childskip' $F)  cap 行=$(grep -ac 'KSUBIRTH cap' $F)"
        echo "    ★dupskip/childskip 的最大 n(每 256 次才打一条 ⇒ n≈被挡掉的总次数)：$(grep -ao 'dupskip n=[0-9]*' $F | tail -1) / $(grep -ao 'childskip n=[0-9]*' $F | tail -1)"
        echo "    ★逐 pid 的 queued self fd 次数(第 51 发主判据：每个 pid 必须恰好 1)："
        grep -a 'queued self fd' $F | sed 's/.*queued self fd pid=\([0-9]*\) comm=\[\([^]]*\)\].*/pid=\1 comm=\2/' | sort | uniq -c | sort -rn | head -8 | sed 's/^/      /'
        echo "    逐 pid 的 seen Manager 次数(应与上面一一对应)："
        grep -a 'seen Manager' $F | sed 's/.*seen Manager pid=\([0-9]*\).*/pid=\1/' | sort | uniq -c | sort -rn | head -8 | sed 's/^/      /'
        echo "    逐 pid 的 => fd= 回调次数(同 pid 多次＝叠 fd，正是第 50 发的病)："
        grep -a '=> fd=' $F | sed 's/.*回调跑在 pid=\([0-9]*\) comm=\[\([^]]*\)\].*/pid=\1 comm=\2/' | sort | uniq -c | sort -rn | head -8 | sed 's/^/      /'
        echo "    装载期那段在不在(ERE 交替，toybox BRE 的 \\| 打空⇒一律用 -E)：命中=$(grep -acE 'KSUBEAT L5|version 32601|ADD_TRY_UMOUNT|allowlist version' $F)"
        grep -a KSUBIRTH $F | head -8 | sed 's/^/      KB /'
        grep -a 'KSUFDINST' $F | head -10 | sed 's/^/      KI /'
    done
    echo "--- 现在的 Manager 与它的 fd(和装载期那一条对表) ---"
    P=$(pidof me.weishu.kernelsu | cut -d' ' -f1)
    echo "    Manager pid=[$P] fd_ksu=$(ls -l /proc/$P/fd 2>/dev/null | grep -ac ksu_driver) 出生=/proc/$P 的 stat 第 22 列=$(awk '{print $22}' /proc/$P/stat 2>/dev/null)"
    echo "===== DONE W694 ====="
} > $L 2>&1
echo "W694 rc=$? out=$L"
