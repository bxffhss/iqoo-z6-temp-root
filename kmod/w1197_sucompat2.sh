#!/system/bin/sh
# w1197：先删掉 overlay 上层的 su（路径真不存在），验内核 sucompat 是否独立成立；再懒卸载清场
OUT=/data/local/tmp/w1197_sucompat2.out
: > "$OUT"
log(){ echo "$@" >> "$OUT"; }
log "=== root=$(id -u) up=$(cut -d' ' -f1 /proc/uptime)s ==="

log "--- [1] 删掉上层 su，让 /system/bin/su 真的不存在 ---"
rm -f /system/bin/su 2>>"$OUT"; log "rm rc=$?"
log "/system/bin/su: $(ls -l /system/bin/su 2>&1 | tr -s ' ')"
log "which su: [$(command -v su 2>&1)]"
log "lower 完好: $(ls /system/bin/sh /system/bin/id /system/bin/am /system/bin/toybox 2>&1 | tr '\n' '|')"

log "--- [2] 无文件时 execve(\"/system/bin/su\") 是否被内核改道 ---"
log "  正对照 10667(已授权)："
/data/local/tmp/asuid 10667 /system/bin/su -c id >>"$OUT" 2>&1; log "  rc=$?"
log "  负对照 2000(未授权)："
/data/local/tmp/asuid 2000 /system/bin/su -c id >>"$OUT" 2>&1; log "  rc=$?"

log "--- [3] bare \"su\"（PATH 扫描，execvp 逐个 execve）---"
/data/local/tmp/asuid 10667 /system/bin/sh -c 'su -c id' >>"$OUT" 2>&1; log "  rc=$?"

log "--- [4] 清场：懒卸载 overlay + 回收 ext4/loop ---"
umount -l /system/bin 2>>"$OUT"; log "umount -l /system/bin rc=$?"
umount /data/local/tmp/ovl_ext4_mnt 2>>"$OUT"; log "umount ext4 rc=$?"
LOOP=$(losetup -j /data/local/tmp/ovl_ext4.img 2>/dev/null | cut -d: -f1 | head -1)
[ -n "$LOOP" ] && { losetup -d "$LOOP" 2>>"$OUT"; log "losetup -d $LOOP rc=$?"; }

log "--- [5] 清场后 ---"
log "overlay 行数: $(grep -c ' /system/bin ' /proc/mounts)"
log "ext4 行数: $(grep -c ovl_ext4 /proc/mounts)"
log "/system/bin/su: $(ls -l /system/bin/su 2>&1 | tr -s ' ')"
log "which su: [$(command -v su 2>&1)]"
log "基础件: $(ls /system/bin/sh /system/bin/id /system/bin/am 2>&1 | tr '\n' '|')"
log "负对照再来一次(无文件+无overlay) 10667:"
/data/local/tmp/asuid 10667 /system/bin/su -c id >>"$OUT" 2>&1; log "  rc=$?"
echo "===== DONE =====" >> "$OUT"
