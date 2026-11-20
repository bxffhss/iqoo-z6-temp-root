#!/system/bin/sh
# w1196：卸掉 overlay（让 /system/bin/su 真的不存在），验证内核 sucompat 是否仍能提供 su
OUT=/data/local/tmp/w1196_sucompat.out
: > "$OUT"
log(){ echo "$@" >> "$OUT"; }
log "=== root=$(id -u) up=$(cut -d' ' -f1 /proc/uptime)s ==="

log "--- [0] 现态 ---"
log "overlay 在? $(grep -c ' /system/bin ' /proc/mounts)  /system/bin/su: $(ls -l /system/bin/su 2>&1 | tr -s ' ')"
log "ksu_ksud_path 目标: $(ls -l /data/local/tmp/kd 2>&1 | tr -s ' ')"
log "ksu_args: $(cat /data/local/tmp/ksu_args.txt 2>&1)"

log "--- [1] 卸 overlay（只去掉我们加的那层）---"
umount /system/bin 2>>"$OUT"; log "umount rc=$?"
log "overlay 还在? $(grep -c ' /system/bin ' /proc/mounts)"
log "/system/bin/su: $(ls -l /system/bin/su 2>&1 | tr -s ' ')"
log "which su: [$(command -v su 2>&1)]"
log "lower 完好: $(ls /system/bin/sh /system/bin/id /system/bin/am 2>&1 | tr '\n' '|')"

log "--- [2] 文件不存在时 execve(\"/system/bin/su\") 还灵不灵 ---"
log "  正对照 10667(已授权)：期望 sucompat 改道 -> uid=0"
/data/local/tmp/asuid 10667 /system/bin/su -c id >>"$OUT" 2>&1; log "  rc=$?"
log "  负对照 2000(未授权)：期望被拒"
/data/local/tmp/asuid 2000 /system/bin/su -c id >>"$OUT" 2>&1; log "  rc=$?"
log "  旁证 10349(本轮被 setprof 授权过)：期望 uid=0"
/data/local/tmp/asuid 10349 /system/bin/su -c id >>"$OUT" 2>&1; log "  rc=$?"

log "--- [3] 路径走 PATH 的形态（bare \"su\"，靠 execvp 逐个试）---"
/data/local/tmp/asuid 10667 /system/bin/sh -c 'su -c id' >>"$OUT" 2>&1; log "  rc=$?"

log "--- [4] dmesg 里 sucompat 的痕迹（最后 8 行）---"
dmesg 2>/dev/null | grep -iE "sucompat|SUCOMPAT|ksu_handle_execve" | tail -8 >>"$OUT"
echo "===== DONE =====" >> "$OUT"
