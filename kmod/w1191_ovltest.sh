#!/system/bin/sh
# w1191：隔离实验——overlayfs 到底哪里 EINVAL
OUT=/data/local/tmp/w1191_ovltest.out
: > "$OUT"
log(){ echo "$@" >> "$OUT"; }
log "=== root $(id) ==="

B=/data/local/tmp/ovlt
rm -rf "$B" 2>/dev/null
mkdir -p "$B/A/lower" "$B/A/upper" "$B/A/work" "$B/A/mnt" || log "! mkdir A"
echo hello > "$B/A/lower/hello.txt"
mkdir -p "$B/A/upper2" "$B/A/work2"
echo up > "$B/A/upper2/added.txt"

log "--- 测试A：lower/upper/work 全在 /data（f2fs）---"
mount -t overlay overlay -o "lowerdir=$B/A/lower,upperdir=$B/A/upper2,workdir=$B/A/work2" "$B/A/mnt" 2>>"$OUT"
log "A rc=$?"
ls "$B/A/mnt" >>"$OUT" 2>&1
umount "$B/A/mnt" 2>>"$OUT"; log "A umount rc=$?"

log "--- 测试A2：opts 加 index=off,metacopy=off ---"
mount -t overlay overlay -o "lowerdir=$B/A/lower,upperdir=$B/A/upper2,workdir=$B/A/work2,index=off,metacopy=off" "$B/A/mnt" 2>>"$OUT"
log "A2 rc=$?"
umount "$B/A/mnt" 2>>"$OUT"; log "A2 umount rc=$?"

log "--- 测试B：lower=/system/bin(erofs ro)，目标在 /data ---"
mkdir -p "$B/B/upper" "$B/B/work" "$B/B/mnt"
mount -t overlay overlay -o "lowerdir=/system/bin,upperdir=$B/B/upper,workdir=$B/B/work" "$B/B/mnt" 2>>"$OUT"
log "B rc=$?"
ls "$B/B/mnt/sh" >>"$OUT" 2>&1
umount "$B/B/mnt" 2>>"$OUT"; log "B umount rc=$?"

log "--- 测试C：直接挂到 /system/bin（source=none）---"
mount -t overlay none -o "lowerdir=/system/bin,upperdir=/data/local/tmp/ovl_sysbin_upper,workdir=/data/local/tmp/ovl_sysbin_work" /system/bin 2>>"$OUT"
log "C rc=$?"

log "--- 内核 dmesg（overlay 相关）---"
dmesg 2>/dev/null | grep -i overlay | tail -20 >>"$OUT" 2>&1
log "--- /proc/filesystems / 模块 ---"
grep overlay /proc/filesystems >>"$OUT"
ls /sys/module/ | grep -i overlay >>"$OUT" 2>&1
log "--- /data 文件系统 ---"
grep " /data " /proc/mounts >>"$OUT"
echo "===== DONE =====" >> "$OUT"
