#!/system/bin/sh
# w199_senwatch.sh —— 一条腿同时办两件事(下次起窗时挂在旁边跑，不额外花窗口)：
#   ① #55(B)：抓 `Permissive → Enforcing` 那一跳**前后各 3 行**的进程表，看谁新出现(§6.198⑧：那一跳发生在 punch 后 16 秒内、mod=0)
#   ② §6.198②的 fork-exec 风暴：每行带 `nproc` 与 `nsh`，哪一路在涨就顺着 PPid 找父进程
# ★两条自证(观测器自己会死，§6.199⑨)：每行都打 `up=`；结尾一定打 `SAMPLE-END n=<行数>`，
#   这样"停在第几行"能区分"被杀"与"跑完"。用 shell 身份跑(不需要 root 通道，也不占 suw 那条腿)。
L=/data/local/tmp/w199_senwatch.log
P=/data/local/tmp/w199_ps.txt
: > "$L"; : > "$P"; chmod 666 "$L" "$P" 2>/dev/null
echo "=== senwatch 起 up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1) id=$(id) ===" >> "$L"
i=0; PREV=""
while [ "$i" -lt 200 ]; do
    i=$((i + 1))
    U=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1)
    E=$(getenforce 2>&1)
    NP=$(ls /proc 2>/dev/null | grep -cE '^[0-9]+$')
    NS=$(ps -A -o NAME 2>/dev/null | grep -c '^sh$')
    echo "up=$U enf=$E nproc=$NP nsh=$NS" >> "$L"
    if [ "$E" != "$PREV" ] && [ -n "$PREV" ]; then
        echo "--- 变化点(上一行是 $PREV)：抓一份进程表快照到 $P ---" >> "$L"
        { echo "### up=$U 从 $PREV 变成 $E"; ps -A -o PID,PPID,UID,STAT,NAME 2>/dev/null; } >> "$P"
    fi
    PREV="$E"
    sleep 2
done
echo "SAMPLE-END n=$i up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1)" >> "$L"
