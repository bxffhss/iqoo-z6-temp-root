#!/system/bin/sh
# ksu_module_teardown.sh —— 把窗口内挂上的模块**清干净**(root 侧跑，配合"不留持久化")
# 判据不是"umount 返回 0"，而是 umount 之后**内容变回原样**：每个目标都取 after2 的 md5，
# 与 apply 时记下的 before 比(记在 ksu_mod_before.txt)。
REC=/data/local/tmp/ksu_mod_mounts.txt
BEF=/data/local/tmp/ksu_mod_before.txt
MOD=${1:-/data/local/tmp/mod}
LOG=/data/local/tmp/ksu_mod_teardown.log
: > "$LOG"
exec >> "$LOG" 2>&1
log() { echo "[$(date +%H:%M:%S)] $*"; sync; }
upt() { cut -d' ' -f1 /proc/uptime; }

log "===== 清场开始 uid=$(id -u) up=$(upt) ====="
[ "$(id -u)" = "0" ] || { log "!! 不是 root ⇒ 什么都做不了"; exit 1; }

log "----- ① 先杀模块留下的进程(否则 umount 会被 busy 挡住，而且它还在吃窗口) -----"
# ★第三十九发的教训：原来这里 `pgrep -f "$MOD"` 把 **teardown 自己的命令行**(参数就是 $MOD)
#   也匹配上 ⇒ 把自己 kill 掉，日志停在第 4 行，`umount` 那一格永远没验。
#   同一个坑今天第二次(前一次是 `pkill -f /data/local/tmp/shd` 杀掉自己那条 adb shell)。
#   ⇒ 改成：①先 umount(不依赖杀进程)；②要杀只匹配 "$MOD/"(带斜杠)且跳过 $$/$PPID；
#   ③无论如何都走到最后的 rm。
log "----- ① 本脚本 pid=$$ PPID=$PPID MOD=$MOD(后面的杀进程步骤会跳过这两个) -----"

log "----- ② 逆序 umount -----"
if [ -s "$REC" ]; then
    # ★toybox 没 tac 就 tail -r 反着读；正着 umount 会被嵌套挂载挡住
    for d in $(tail -r "$REC" 2>/dev/null || sort -r "$REC"); do
        [ -n "$d" ] || continue
        timeout 5 /data/local/tmp/suwbind --umount "$d" 2>&1
        log "  还在 mountinfo 里?=$(/data/local/tmp/suwbind --check "$d" >/dev/null 2>&1 && echo 是 || echo 否)"
    done
fi
: > "$REC"

log "----- ③ 内容有没有真的变回原样(这才是判据) -----"
if [ -f "$BEF" ]; then
    while read -r path md5; do
        [ -n "$path" ] || continue
        NOW=$(timeout 5 md5sum "$path" 2>/dev/null | cut -d' ' -f1)
        if [ "$NOW" = "$md5" ]; then R=恢复; else R="!!还是模块版"; fi
        log "  $path before=$md5 now=$NOW ⇒ $R"
    done < "$BEF"
else
    log "  没有 $BEF ⇒ 无法对比(apply 那版得记 before)"
fi

log "----- ③′ umount 之后再处理模块自己起的进程(匹配串带斜杠，绝不匹配到自己) -----"
for q in $(pgrep -f "$MOD/" 2>/dev/null); do
    [ "$q" = "$$" ] && continue
    [ "$q" = "$PPID" ] && continue
    log "  kill $q [$(tr '\0' ' ' < /proc/$q/cmdline 2>/dev/null)]"
    kill -9 "$q" 2>/dev/null
done

log "----- ④ 删掉模块落地物(不留持久化) -----"
rm -rf /data/adb/modules "$MOD" /data/local/tmp/testmod.zip \
     /data/local/tmp/ksu_mod_selftest.txt /data/local/tmp/ksu_mod_apply.log
log "  /data/adb=[$(ls -l /data/adb 2>&1 | tr '\n' ' ')]"
log "===== 清场结束 up=$(upt) ====="
chmod 666 "$LOG" 2>/dev/null
sync
