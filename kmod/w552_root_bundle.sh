#!/system/bin/sh
# w552_root_bundle.sh —— 第 43 发(凭据收口)的**一次派发干完三件事**，因为 suw 的 root agent 一次只接一单
#   且跑完孩子变僵尸(#205) ⇒ 不能分三次派。两件"软重启框架"用**信号文件**跟我握手，脚本自己在窗口里等。
#   ★规矩同 §6.x：重定向写在脚本内部(打字链会吃 `>`)；工具绝对路径；kill 之前先 sync 并落盘(#186 一族)。
OUT=/data/local/tmp/w552_root.out
CUE1=/data/local/tmp/w552_cue1
CUE2=/data/local/tmp/w552_cue2
: > "$OUT"; chmod 666 "$OUT" 2>/dev/null
MSYS=/data/local/tmp
say() { echo "$1" >> "$OUT"; }

say "== 0) 身份与起点 =="
/system/bin/id >> "$OUT" 2>&1
say "enforce=$(getenforce) up=$(cut -d. -f1 /proc/uptime) mod=$(grep -ac kernelsu /proc/modules)"

say "== 1) #167：/data/adb 残留，这次带 ls 硬复证(上一发 rmdir 报 Directory not empty) =="
say "清之前 ls -a /data/adb = [$(ls -a /data/adb 2>&1 | tr '\n' ' ')]"
/system/bin/rm -r /data/adb/ksu 2>>"$OUT"; say "rm_r_ksu_rc=$?"
/system/bin/rm -f /data/adb/ksud /data/adb/.suwtest 2>>"$OUT"; say "rm_files_rc=$?"
say "清之后 ls -a /data/adb = [$(ls -a /data/adb 2>&1 | tr '\n' ' ')]"
say "细看(还在的就是没清掉)：$(ls -l /data/adb 2>&1 | tr '\n' '|')"

say "== 2) 给 Termux 现取 uid 并授权(判据②/#164 要它) =="
TU=$(pm list packages -U 2>/dev/null | grep -a '^package:com.termux uid:' | tail -1 | sed 's/.*uid://' | tr -dc '0-9')
say "Termux uid 现取=[$TU]"
if [ -n "$TU" ]; then
    $MSYS/ksuctl grant "$TU" >> "$OUT" 2>&1; say "grant rc=$?"
    $MSYS/ksuctl granted "$TU" >> "$OUT" 2>&1; say "granted rc=$?"
    say "名单读回：$($MSYS/ksuctl allowlist 2>&1 | tr '\n' '|' | cut -c1-300)"
else
    say "没取到 uid ⇒ 这一格没做"
fi

say "== 3) 等第 1 次软重启口令(CUE1，最多 420 秒)：先拍完 RACE 期与常驻种子的图 =="
N=0
while [ ! -f "$CUE1" ]; do
    N=$((N + 1)); [ "$N" -gt 210 ] && break
    /system/bin/sleep 2
done
if [ -f "$CUE1" ]; then
    say "收到 CUE1 up=$(cut -d. -f1 /proc/uptime)  ⇒ 软重启框架(杀 system_server+zygote64，不动内核)"
    SS=$(pidof system_server | cut -d' ' -f1); ZG=$(pidof zygote64 | cut -d' ' -f1)
    say "pid system_server=[$SS] zygote64=[$ZG]"
    /system/bin/sync
    [ -n "$SS" ] && /system/bin/kill -9 "$SS" 2>>"$OUT"
    [ -n "$ZG" ] && /system/bin/kill -9 "$ZG" 2>>"$OUT"
    say "kill 发完 up=$(cut -d. -f1 /proc/uptime) mod=$(grep -ac kernelsu /proc/modules)"
else
    say "没等到 CUE1(420 秒) ⇒ 第一次软重启没做"
fi

say "== 4) 等第 2 次软重启口令(CUE2，最多 900 秒；那之前我会把常驻开关删掉＝#168③ 的反对照) =="
rm -f "$CUE1" 2>/dev/null
N=0
while [ ! -f "$CUE2" ]; do
    N=$((N + 1)); [ "$N" -gt 450 ] && break
    /system/bin/sleep 2
done
if [ -f "$CUE2" ]; then
    SS=$(pidof system_server | cut -d' ' -f1); ZG=$(pidof zygote64 | cut -d' ' -f1)
    say "收到 CUE2 up=$(cut -d. -f1 /proc/uptime) ⇒ 第二次软重启(system_server=[$SS] zygote64=[$ZG] 开关在否=[$(/system/bin/ls /data/local/tmp/ksu_fd_keepalive 2>&1 | tr '\n' ' ')])"
    /system/bin/sync
    [ -n "$SS" ] && /system/bin/kill -9 "$SS" 2>>"$OUT"
    [ -n "$ZG" ] && /system/bin/kill -9 "$ZG" 2>>"$OUT"
    say "第二次 kill 发完 up=$(cut -d. -f1 /proc/uptime)"
else
    say "没等到 CUE2(900 秒) ⇒ 反对照那半格没做"
fi
rm -f "$CUE2" 2>/dev/null
sync
say "== 9) 结束读数 =="
say "up=$(cut -d. -f1 /proc/uptime) mod=$(grep -ac kernelsu /proc/modules) enf=$(getenforce)"
say "===== DONE ====="
