#!/system/bin/sh
# w423（§6.599 续）—— Exp-6b 的 root 腿。只做「shell 域做不到」的两件事，别的一律不碰：
#   ① 删 /data/local/tmp/kd：它的标签是 u:object_r:apk_data_file:s0，shell 域没有 unlink
#      ⇒ 实测 `rm -f` 直接 Permission denied(rc=1)、文件仍在（正负对照见账本 §6.599：
#      同目录 shell 自建的 shell_data_file 文件删得掉）。属主本来就是 shell，别再往属主上查。
#   ② 清 /data/adb 的 ksu/ksud 脚印并打印前后状态：shell 读不到这个目录，
#      go.sh 第 4 步那支腿本发没跑成 ⇒ 名单文件在不在一直是「未知」，本腿把它变成读数。
# 判据：OUT 里必须出现 kd_gone；末尾那行 END up= 是给 go.sh 的 WAITFOR 用的
#      （缺了它整格会被记成「未测」而不是「通过」）。
OUT=/data/local/tmp/w423_out.txt
: > "$OUT"
log() { echo "$@" >> "$OUT"; }

log "=== W423 BEGIN uid=$(id -u) up=$(cut -d' ' -f1 /proc/uptime) ==="

log "--- kd before ---"
ls -lZ /data/local/tmp/kd >> "$OUT" 2>&1
rm -f /data/local/tmp/kd >> "$OUT" 2>&1
RC=$?
log "rm_rc=$RC"
if [ -e /data/local/tmp/kd ]; then log "kd_still_there"; else log "kd_gone"; fi
log "--- kd after ---"
ls -lZ /data/local/tmp/kd >> "$OUT" 2>&1

log "--- /data/adb before ---"
ls -la /data/adb >> "$OUT" 2>&1
rm -rf /data/adb/ksu /data/adb/ksud >> "$OUT" 2>&1
log "adb_rm_rc=$?"
log "--- /data/adb after ---"
ls -la /data/adb >> "$OUT" 2>&1

sync
log "=== W423 END up=$(cut -d' ' -f1 /proc/uptime) ==="
