#!/system/bin/sh
# w1192：沙箱验证 tmpfs 当 upper 能否过 ovl_dentry_weird（只在本进程 ns，无害）
OUT=/data/local/tmp/w1192_tmpfsupper.out
: > "$OUT"
log(){ echo "$@" >> "$OUT"; }
log "=== root $(id) ==="

log "--- 能力侦察 ---"
log "tmpfs: $(grep -c tmpfs /proc/filesystems)"
log "toybox nsenter: $(/data/local/tmp/toybox nsenter --help >/dev/null 2>&1 && echo yes || echo no)"
log "toybox unshare: $(/data/local/tmp/toybox unshare --help >/dev/null 2>&1 && echo yes || echo no)"
log "本进程 mnt ns: $(readlink /proc/self/ns/mnt)  init: $(readlink /proc/1/ns/mnt)"
log "propagation(self): $(grep -E ' / | /system ' /proc/self/mountinfo | head -2)"

T=/data/local/tmp/ovlt2
rm -rf "$T" 2>/dev/null
mkdir -p "$T" || log "! mkdir T"
log "--- 挂 tmpfs ---"
mount -t tmpfs -o mode=0755,size=64m tmpfs "$T" 2>>"$OUT"
log "tmpfs rc=$?"
mkdir -p "$T/upper" "$T/work" "$T/mnt" 2>>"$OUT"
cp /data/local/tmp/ksu_su "$T/upper/su" 2>>"$OUT"
chown 0:0 "$T/upper/su" 2>>"$OUT"; chmod 0755 "$T/upper/su" 2>>"$OUT"
ls -l "$T/upper/su" >>"$OUT" 2>&1

log "--- overlay: tmpfs upper + erofs lower(/system/bin) ---"
mount -t overlay overlay -o "lowerdir=/system/bin,upperdir=$T/upper,workdir=$T/work" "$T/mnt" 2>>"$OUT"
ORC=$?
log "overlay rc=$ORC"
if [ $ORC -eq 0 ]; then
  log "merged 列表(抽查): $(ls "$T/mnt" 2>&1 | head -5 | tr '\n' '|')"
  log "su 可见: $(ls -l "$T/mnt/su" 2>&1 | tr -s ' ')"
  log "sh 可见: $(ls -l "$T/mnt/sh" 2>&1 | tr -s ' ')"
  log "--- 从 merged 里执行 su（root 身份）---"
  "$T/mnt/su" -c 'id' >>"$OUT" 2>&1
  log "exec rc=$?"
  umount "$T/mnt" 2>>"$OUT"; log "umount overlay rc=$?"
fi
umount "$T" 2>>"$OUT"; log "umount tmpfs rc=$?"
log "--- dmesg overlay 尾 ---"
dmesg 2>/dev/null | grep -i overlay | tail -6 >>"$OUT"
echo "===== DONE =====" >> "$OUT"
