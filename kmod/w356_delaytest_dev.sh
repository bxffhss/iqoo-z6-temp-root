#!/system/bin/sh
# w356_delaytest_dev.sh —— 只测一件事：这台 mksh 上哪种"零 fork"延时是真的(读不到就退回 sleep，别拿假的当仪器)。
O=/data/local/tmp/w356_delaytest.out
{
    echo "uid=$(id -u)"
    S=$(date +%s%N); read -t 1 _A < /dev/null; E=$(date +%s%N)
    echo "read -t 1 < /dev/null      = $(( (E-S)/1000000 ))ms"
    S=$(date +%s%N); sleep 1; E=$(date +%s%N)
    echo "sleep 1(参照,1 个 fork)     = $(( (E-S)/1000000 ))ms"
    mkfifo /data/local/tmp/w356_fifo 2>/dev/null
    echo "mkfifo rc=$? 存在=$([ -p /data/local/tmp/w356_fifo ] && echo y || echo n)"
    S=$(date +%s%N); read -t 1 _B <> /data/local/tmp/w356_fifo; E=$(date +%s%N)
    echo "read -t 1 <> fifo          = $(( (E-S)/1000000 ))ms  (≈1000 ⇒ 这条路可用)"
    S=$(date +%s%N); i=0; while [ $i -lt 3 ]; do read -t 1 _C <> /data/local/tmp/w356_fifo; i=$((i+1)); done; E=$(date +%s%N)
    echo "read -t 1 <> fifo x3       = $(( (E-S)/1000000 ))ms  (≈3000 ⇒ 才是真延时)"
    P0=$(grep -m1 '^processes' /proc/stat | cut -d' ' -f2)
    i=0; while [ $i -lt 10 ]; do read -t 1 _D <> /data/local/tmp/w356_fifo; i=$((i+1)); done
    P1=$(grep -m1 '^processes' /proc/stat | cut -d' ' -f2)
    echo "10 次 fifo 延时期间 procs 增量=$((P1-P0))(这段时间自己不该起进程，应当≈空闲基线×10s)"
    rm -f /data/local/tmp/w356_fifo
    echo "[===== DONE =====]"
} > "$O" 2>&1
