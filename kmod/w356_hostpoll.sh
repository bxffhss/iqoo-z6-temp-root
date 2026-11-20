#!/usr/bin/env bash
# w356_hostpoll.sh —— 第 122 发的第二条腿：**从宿主机**每 ~5 秒问一次"在场的是谁"。
# 用法：bash kmod/w356_hostpoll.sh <存证名> <次数=240 ⇒ 20 分钟>
# ★为什么把"谁在 fork"放到宿主机侧问：设备侧那条腿(w356_storm_dev.sh)要**尽量少起进程**才能当速率基线；
#   而"进程名/父子关系"这种细节只有 `ps` 给得出，与其让设备每 0.2 秒 dump 一次(自己造噪声)，
#   不如我这边每 5 秒问一次——**问的人是我，噪声算我的，账要写清楚**(每次问 ≈ 6 个设备侧进程)。
# ★产物在**本机**，不在设备：复位也带得走；且它带的是**本机钟**(比设备慢 29 秒)⇒ 与 stage 日志对表时先换算，见 §6.261②。
set -u
export MSYS_NO_PATHCONV=1
TAG=${1:-t0}; N=${2:-240}
OUT="kmod/w103_evidence/w356_hostpoll_${TAG}.txt"
: > "$OUT"
echo "hostpoll 起 本机钟=$(date +%H:%M:%S) 计划=$N 次(每次≈6 个设备侧进程) 差值判据:设备钟=本机钟+29s" >> "$OUT"
i=0
while [ "$i" -lt "$N" ]; do
    i=$((i+1))
    L=$(timeout 12 adb shell "read UP D < /proc/uptime; echo \"up=\$UP\"; \
        echo \"mgr=\$(pidof me.weishu.kernelsu) sup=\$(pidof com.suprobe.app) suw=\$(pidof com.suw.manager) kd=\$(pidof kd)\"; \
        echo \"crashn=\$(ps -eo name 2>/dev/null | grep -acE 'crash_dump64|debuggerd64|debuggerd')\"; \
        ps -eo pid,ppid,name 2>/dev/null | sort -n -k1 | tail -14" 2>/dev/null | tr -d '\r')
    if [ -z "$L" ]; then
        echo "$(date +%H:%M:%S) h$i <adb 没回> ★掉总线/重启中" >> "$OUT"
    else
        { echo "----- $(date +%H:%M:%S) h$i -----"; echo "$L"; } >> "$OUT"
    fi
    sleep 5
done
echo "$(date +%H:%M:%S) hostpoll 收工" >> "$OUT"
