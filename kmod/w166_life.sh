#!/system/bin/sh
# w166_life.sh —— 模块寿命采样器(#55/#39)。setsid 常驻，每 10s 一行，跑满 1200s。
#   为什么要有它：今晚四跑里三跑"insmod 后 1~2 分钟出事"，但我只知道"下一次连上时已经没了"，
#   拿不到**消失的那一刻**和它前后的东西(负载？谁在跑？enforce 有没有先翻回去？)。
# ★落盘在 /data/local/tmp ⇒ 机器复位也还在；chmod 666 ⇒ 复位后 shell 读得动(不需要再拿 root)。
# ★每一行都自带 up= 与一个 DONE 之外的形状，绝不"等文件存在"当写完(§6.141)。
L=/data/local/tmp/w166_life.log
i=0
: > "$L"; chmod 666 "$L"
while [ "$i" -lt 120 ]; do
    i=$((i + 1))
    U=$(cut -d' ' -f1 /proc/uptime)
    M=$(grep -c kernelsu /proc/modules 2>/dev/null)
    F=$([ -e /proc/ksu_install_fd ] && echo y || echo n)
    E=$(getenforce 2>/dev/null)
    LA=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
    UN=$(uname -s 2>/dev/null)
    R=$(grep -c '^' /proc/sched_debug 2>/dev/null); R=${R:-x}
    # ★uts 也进每一行(§6.162)：#55 现在最好的线索是"punch 把 sysname 打成 Linu 的那两跑都死了(2/2)，
    #   uts 正常的跑 6 次只死 1 次" ⇒ 这个自变量以后每次都要留痕，不然攒不出对照。
    echo "LIFE up=$U mod=$M fd_node=$F enf=$E load1=$LA uts=$UN" >> "$L"
    if [ "$M" = "0" ] && [ "$i" -gt 3 ]; then
        echo "LIFE-END up=$U reason=mod-gone samples=$i" >> "$L"
        break
    fi
    sleep 10
done
echo "LIFE-DONE samples=$i up=$(cut -d' ' -f1 /proc/uptime)" >> "$L"
chmod 666 "$L"
