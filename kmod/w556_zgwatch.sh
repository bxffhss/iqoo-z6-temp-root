#!/system/bin/sh
# w556_zgwatch.sh —— 0 枪只读：查 `pidof zygote64` 在当前(健康基线)有几个候选、各自的 ppid/comm/starttime/cmdline，
#   并用 `pidof system_server` 的 ppid 当"真 zygote"的独立证人。
#   为什么现在要查：第 43 发 FDKA 日志里 `INST Z` 的 pid 在 100 秒内换了 8 个值，而 ppid=1 这道过滤本应只放行真 zygote。
#   注：这台机没有"零 fork 的延时"，节拍只能用 sleep(1 fork/秒)，读数一律 read/cut 自 /proc。
N=${1:-90}
i=0
ZG=/data/local/tmp/w556_zg.out
: > "$ZG"
while [ "$i" -lt "$N" ]; do
    i=$((i + 1))
    UP=$(cut -d' ' -f1 /proc/uptime)
    SS=$(pidof system_server 2>/dev/null | cut -d' ' -f1)
    SSP=$(read -r A B C D _ < /proc/$SS/stat 2>/dev/null; echo "$D")
    LIST=$(pidof zygote64 2>/dev/null)
    CN=0
    for P in $LIST; do
        case "$P" in ''|*[!0-9]*) continue ;; esac
        CN=$((CN + 1))
        F=$(cut -d' ' -f1,2,3,4,22 "/proc/$P/stat" 2>/dev/null)
        C=$(tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null | cut -c1-70)
        echo "up=$UP cand=[$F] cn=$CN ss_ppid=$SSP cmd=[$C]" >> "$ZG"
    done
    echo "up=$UP n=$CN list=[$LIST] ss=$SS ss_ppid=$SSP" >> "$ZG"
    sleep 1
done
echo "ZGWATCH DONE up=$(cut -d' ' -f1 /proc/uptime) samples=$i file=$(wc -c < $ZG)"
