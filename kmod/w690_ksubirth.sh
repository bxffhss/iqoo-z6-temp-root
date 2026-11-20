#!/system/bin/sh
# w690_ksubirth.sh v2 —— 第 50 发（rc74「Manager 出生即装 fd」）的**内核证人读数腿**（root 侧跑）。
#   ★v1 的坑(第一版就在这发当场把自己骗了)：把 dmesg 整个塞进变量再 `printf '%s\n' "$D"` ⇒
#     mksh 的 exec 参数上限直接报 `/system/bin/printf: Argument list too long`，**六个计数全打 0**——
#     那 0 是"抽取器炸了"，长得却和"内核没打印"一模一样(例 170/173 那一族)。
#   v2＝dmesg 先落一个临时文件，**先打印它的行数/字节数当输入证人**，再对文件 grep；文件不在或 0 行 ⇒ 全部算"未测"。
#   ★匹配式一律 ASCII(toybox grep 对 CJK 与 `\|` 不可靠)：「已排队」取兄弟行 `queued self fd`，「回调跑在」取 `=> fd=`。
PATH=/system/bin:/system/xbin:/product/bin:/vendor/bin:$PATH
export PATH
L=/data/local/tmp/w690_ksubirth.out
K=/data/local/tmp/w690_dmesg.txt
MGR=me.weishu.kernelsu
{
    echo "=== W690v2 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) boot_id=$(cat /proc/sys/kernel/random/boot_id) ==="
    dmesg > $K 2>&1
    RK=$?
    NL=$(grep -ac . $K 2>/dev/null)
    NB=$(wc -c < $K 2>/dev/null)
    echo "  【输入证人】dmesg rc=$RK 行数=$NL 字节=$NB"
    echo "  首行=[$(head -1 $K 2>/dev/null | cut -c1-70)]  末行=[$(tail -1 $K 2>/dev/null | cut -c1-70)]"
    if [ "${NL:-0}" = "0" ]; then
        echo "  !! dmesg 落下来是空的 ⇒ 下面所有计数一律算【未测】，不许当 0 次读(例 166/170)"
    fi

    echo "--- ① KSUBIRTH 四支各自计数(看见⇒排队⇒分配失败⇒排队失败) ---"
    for t in 'seen Manager' 'queued self fd' 'kzalloc(ATOMIC) failed' 'task_work_add pid'; do
        echo "    [$t] = $(grep -ac "$t" $K)"
    done
    echo "    KSUBIRTH 总条数=$(grep -ac KSUBIRTH $K)"
    grep -a KSUBIRTH $K > /data/local/tmp/w690_ksubirth_lines.txt 2>&1
    echo "    全量 KSUBIRTH 已另存 /data/local/tmp/w690_ksubirth_lines.txt 行数=$(grep -ac . /data/local/tmp/w690_ksubirth_lines.txt)"
    echo "    按 (pid,comm) 分组的排队次数(去重是不是真在工作)："
    grep -a 'queued self fd' $K | sed 's/.*queued self fd pid=\([0-9]*\) comm=\[\([^]]*\)\].*/\1 \2/' | sort | uniq -c | sort -rn | head -12 | sed 's/^/      /'
    grep -a KSUBIRTH $K | tail -16 | sed 's/^/      /'

    echo "--- ② KSUFDINST：排队⇒回调⇒护栏，主判据要三条同 pid 且时刻递增 ---"
    echo "    回调跑在(=> fd=) = $(grep -ac '=> fd=' $K)"
    echo "    NULLFILES skip   = $(grep -ac 'NULLFILES skip' $K)"
    echo "    KSUFDINST 总条数 = $(grep -ac KSUFDINST $K)"
    grep -a KSUFDINST $K | tail -18 | sed 's/^/      /'

    echo "--- ③ 加冕/manager appid（若 ① 全空先在这儿分家：appid 没设上⇒谓词恒假） ---"
    grep -aE 'ksu_manager_appid|Crowning manager|allow root for' $K | tail -6 | sed 's/^/      /'

    echo "--- ④ 驱动 fd 的独立证人：Manager 自己表里那条 anon_inode ---"
    P=$(pidof $MGR | cut -d' ' -f1)
    echo "    Manager pid=[$P] cmdline=[ $(tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null) ] start_ticks=$(cut -d' ' -f22 /proc/$P/stat 2>/dev/null)"
    if [ -n "$P" ]; then
        ls -l /proc/$P/fd 2>&1 | grep -a ksu_driver | head -6 | sed 's/^/      /'
        echo "    fd_ksu=$(ls -l /proc/$P/fd 2>/dev/null | grep -ac ksu_driver)  fd 总数=$(ls /proc/$P/fd 2>/dev/null | grep -ac .)"
    fi

    echo "--- ⑤ 反夹具：还有没有**别的生产者**活着或留了开关(亮牌子不能算它们的) ---"
    ps -A 2>/dev/null | grep -aE 'w161_g2|w600_mgrwatch|w625_seedrestart|ksu_one_stage|dmesg -w' | grep -av grep | sed 's/^/      /'
    echo "    开关：race=$(ls /data/local/tmp/ksu_race_fd 2>&1|cut -c1-42) keepalive=$(ls /data/local/tmp/ksu_fd_keepalive 2>&1|cut -c1-42) nogate=$(ls /data/local/tmp/w625_nogate 2>&1|cut -c1-38)"
    echo "    锁文件=$(tr '\n' ',' < /data/local/tmp/w625_lock 2>&1)"
    echo "    触发口=$(ls -l /proc/ksu_install_fd 2>&1 | cut -c1-58)"
    echo "    stage 里那条 RACE 回执(装载期抢装的证人，用来分家)：$(grep -a 'RACE' /data/local/tmp/ksu_stage.log 2>/dev/null | tail -3 | tr '\n' '|')"

    echo "--- ⑥ 稳定性：signal 6 / zygote / 模块与 uptime ---"
    echo "    received signal 6 = $(grep -ac 'received signal 6' $K)   zygote 行 = $(grep -ac 'Service .zygote' $K)"
    grep -aE 'received signal 6|Service .zygote' $K | tail -5 | sed 's/^/      /'
    echo "    模块=[$(grep -a kernelsu /proc/modules | cut -d' ' -f1-4)]  up=$(cut -d' ' -f1 /proc/uptime)  boot_id=$(cat /proc/sys/kernel/random/boot_id | cut -c1-8)"
    rm -f $K
    echo "===== DONE W690v2 ====="
} > $L 2>&1
echo "W690 rc=$? out=$L"
