#!/usr/bin/env bash
# w353_watch.sh —— 只读时间轴采样(5s 一行，~40 分钟封顶)：判"这一枪的窗口活多久"。
# ★远端命令里**不出现中文**：`判据⑥` 这行用 ASCII 代理(RACE = stage 判据⑥ 段自己打的"RACE 看门狗已起")，
#   免得 Git Bash→adb 的编码把模式弄没(那会变成"永远 0"的假阴性)。
set -u
export MSYS_NO_PATHCONV=1
OUT=${1:-kmod/w103_evidence/w353_timeline.txt}
: > "$OUT"
for i in $(seq 1 480); do
    L=$(timeout 8 adb shell "echo \$(cut -d' ' -f1 /proc/uptime 2>/dev/null)\|\$(grep -c kernelsu /proc/modules 2>/dev/null)\|\$(getenforce 2>/dev/null)\|\$(grep -ac RACE /data/local/tmp/ksu_stage.log 2>/dev/null)\|\$(dumpsys window 2>/dev/null | grep -a -m1 -o 'mFocusedApp=[^ ]*')" 2>/dev/null | tr -d '\r')
    echo "$(date +%H:%M:%S) up|mod|enf|race|focus = ${L:-<adb 没回>}$( [ -n "$L" ] || echo ' ★空=可能掉总线/重启中')" >> "$OUT"
    sleep 4
done
echo "$(date +%H:%M:%S) [watcher 到点收工]" >> "$OUT"
