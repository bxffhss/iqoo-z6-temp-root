#!/system/bin/sh
# w201_stormwatch.sh —— 风暴计数器 + 谱系抓取(§6.198② 欠的那台仪器)。
#   一手事实：死前 dmesg.live 里 pid 每 ~83ms 涨 20 多个(约 240 进程/秒)，其中 uid=0 comm=sh
#   的 execve 约 130/秒。我们三条腿的量级都撑不起这个数(fdwatch 上限 2.5 次/秒；stage 尾部
#   轮询 ~1 次/秒；心跳循环实测 12 轮/秒) ⇒ 别再猜，直接看"谁有几百个孩子"。
# ★跑在 shell 域，**不要 root**：这条要挂在活证那一跑的旁边，不能碰王座也不能碰 punch。
#   ps -A 的 PID/PPID/UID/COMM 对 shell 都可见(§6 多处已用)，够画谱系了。
# ★自己限量(600 轮 × 2s = 20 分钟)、每轮只 fork 一次 ps —— 计数器不能变成第二个风暴源。
L=${L:-/data/local/tmp/w201_storm.txt}
PIDF=${PIDF:-/data/local/tmp/w201_storm.pid}
# WUID: 只看这个 uid 的 sh；ALL=不限 uid(干跑验证触发器用)。默认看 root 的孩子。
WUID=${WUID:-0}
# RISE: 相邻两轮增量到多少就抓谱系。真机上限 ~130/s ⇒ 2s 窗内 30 已经是很尖的信号。
RISE=${RISE:-30}
N=${N:-600}
SLEEP_S=${SLEEP_S:-2}
echo $$ > "$PIDF"
chmod 666 "$PIDF" "$L" 2>/dev/null
SNAP=/data/local/tmp/w201_snap.txt
# 一轮只 fork 一次 ps(写快照)，两个口径都从快照数 ⇒ 计数器自身开销更低，也不会两次 ps 之间进程变了。
snap() { ps -A -o PID,PPID,UID,STAT,NAME > "$SNAP" 2>/dev/null; }
cnt() {
    # 数当前"名字正好是 sh"的任务(默认再加 uid 过滤)。ps 列序: PID PPID UID STAT NAME。
    # ★取列前先丢掉表头；★uid 用 $3 不是 $2(列错位在这条上会直接数成 0)。
    if [ "$WUID" = ALL ]; then
        tail -n +2 "$SNAP" | awk '$5=="sh"' | wc -l
    else
        tail -n +2 "$SNAP" | awk -v u="$WUID" '$3==u && $5=="sh"' | wc -l
    fi
}
# 风暴的原始口径就是"uid=0 的 sh"，所以不论 WUID 设成什么都固定并报这个数。
cnt0() { tail -n +2 "$SNAP" | awk '$3==0 && $5=="sh"' | wc -l; }
genealogy() {
    # 抓谱系：整份 ps + 按父进程聚合的孩子数(降序前 8) + 被怀疑的 sh 的父链。
    echo "### 抓取 up=$(cut -d' ' -f1 /proc/uptime) 增量 $1(阈值 $RISE) WUID=$WUID" >> "$L"
    # ★用**被数过的那一份快照**画谱系，不再重取一次 ps：干跑里重取的那份已经看不到负向增量的娃
    #   (娃散了) ⇒ "抓到的谱系"和"触发的增量"必须是同一刻的同一份数据。
    cp "$SNAP" /data/local/tmp/w201_ps.txt 2>/dev/null
    echo "    整份 ps 已落 /data/local/tmp/w201_ps.txt ($(wc -l < /data/local/tmp/w201_ps.txt 2>/dev/null) 行)" >> "$L"
    echo "    uid=0 的 sh 数=$(awk '$3==0 && $5=="sh"' "$SNAP" 2>/dev/null | wc -l)(风暴口径，与 WUID 无关)" >> "$L"
    echo "    —— 谁的孩子最多(PPID:个数，前 8；已排掉 PPID=2/0 的内核线程，它们恒占 540/2 会吃掉格子) ——" >> "$L"
    tail -n +2 /data/local/tmp/w201_ps.txt | awk '$2!=2 && $2!=0{c[$2]++} END{for (p in c) print p": "c[p]}' \
        | sort -t: -k2 -rn | head -8 >> "$L"
    echo "    —— 这些孩子各自是谁的娃(前 5 个 sh 的父链) ——" >> "$L"
    tail -n +2 /data/local/tmp/w201_ps.txt | awk '$5=="sh"' | head -5 | while read -r sp spp su ss sn; do
        gp=$(awk -v p="$spp" '$1==p{print $2}' /data/local/tmp/w201_ps.txt)
        gn=$(awk -v p="$gp" '$1==p{print $5}' /data/local/tmp/w201_ps.txt)
        pp=$(awk -v p="$spp" '$1==p{print $5}' /data/local/tmp/w201_ps.txt)
        echo "      sh pid=$sp uid=$su <- 父 pid=$spp comm=[$pp] <- 祖 pid=$gp comm=[$gn]" >> "$L"
    done
    cp /data/local/tmp/w201_ps.txt "/data/local/tmp/w201_ps_$(date +%H%M%S).txt" 2>/dev/null
}
echo "=== W201 风暴计数 up=$(cut -d' ' -f1 /proc/uptime) WUID=$WUID RISE=$RISE N=$N ===" >> "$L"
snap; OLD=$(cnt); OLD0=$(cnt0)
echo "    起点 nsh=$OLD rootsh=$OLD0" >> "$L"
i=0
TRIG=0
while [ "$i" -lt "$N" ]; do
    i=$((i + 1))
    sleep "$SLEEP_S"
    snap
    NOW=$(cnt)
    R0=$(cnt0)
    D=$((NOW - OLD))
    D0=$((R0 - OLD0))
    echo "  [$i] up=$(cut -d' ' -f1 /proc/uptime) nsh=$NOW d=$D rootsh=$R0 d0=$D0" >> "$L"
    # 触发条件里 **rootsh 的增量单独也算**：现场那 130/s 就是 uid=0 的 sh，
    # 而整机 nsh 可能因为别的 uid 波动而把这信号摊平。
    if [ "$D" -ge "$RISE" ] || [ "$D0" -ge "$RISE" ]; then
        TRIG=$((TRIG + 1))
        genealogy "$D/root $D0"
    fi
    # 掉了也算变化：增量的绝对值过大同样抓(进程被收割时 d 是负的，谱系照样有用)。
    if [ "$D" -le "-$RISE" ] || [ "$D0" -le "-$RISE" ]; then
        TRIG=$((TRIG + 1))
        genealogy "负向 $D"
    fi
    OLD=$NOW
    OLD0=$R0
    chmod 666 "$L" 2>/dev/null
done
echo "SAMPLE-END n=$i trig=$TRIG last_nsh=$NOW" >> "$L"
chmod 666 "$L"
