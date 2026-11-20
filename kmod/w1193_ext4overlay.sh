#!/system/bin/sh
# w1193：ext4 镜像当 overlay upper，把 su 放进 /system/bin（复刻 Magisk/KernelSU 做法）
# 只在 /system/bin 上"加一个文件"，lower(erofs) 保持可见；umount /system/bin 即可回退。
if [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
  exec /system/bin/nsenter -t 1 -m /system/bin/sh "$0" "$@"
fi
OUT=/data/local/tmp/w1193_ext4overlay.out
: > "$OUT"
log(){ echo "$@" >> "$OUT"; }

log "=== uid=$(id -u) ns=$(readlink /proc/self/ns/mnt) init=$(readlink /proc/1/ns/mnt) ==="
log "enforce=$(getenforce)  su前=[$(ls /system/bin/su 2>&1)]"

IMG=/data/local/tmp/ovl_ext4.img
MNT=/data/local/tmp/ovl_ext4_mnt
mkdir -p "$MNT" || log "! mkdir MNT"

log "--- 1) 64M ext4 镜像 ---"
if [ ! -f "$IMG" ]; then
  dd if=/dev/zero of="$IMG" bs=1048576 count=64 2>>"$OUT"
  log "dd rc=$?"
  mke2fs -t ext4 -F -q "$IMG" >>"$OUT" 2>&1
  log "mke2fs rc=$?"
fi
log "img: $(ls -l "$IMG" 2>&1 | tr -s ' ')"

log "--- 2) losetup ---"
LOOP=$(losetup -f 2>/dev/null)
log "空闲 loop=[$LOOP]"
if [ -n "$LOOP" ]; then
  losetup "$LOOP" "$IMG" 2>>"$OUT"; log "losetup rc=$?"
  log "--- 3) mount ext4 ---"
  mount -t ext4 -o rw,noatime "$LOOP" "$MNT" 2>>"$OUT"; log "mount ext4 rc=$?"
  grep "$MNT" /proc/mounts >>"$OUT" 2>&1
  mkdir -p "$MNT/upper" "$MNT/work" 2>>"$OUT"
  cp /data/local/tmp/ksu_su "$MNT/upper/su" 2>>"$OUT"; log "cp rc=$?"
  chown 0:0 "$MNT/upper/su" 2>>"$OUT"
  chmod 0755 "$MNT/upper/su" 2>>"$OUT"
  if command -v chcon >/dev/null 2>&1; then
    chcon u:object_r:system_file:s0 "$MNT/upper/su" 2>>"$OUT"; log "chcon rc=$?"
  else
    log "chcon: 无（可忽略，Permissive）"
  fi
  log "upper su: $(ls -l "$MNT/upper/su" 2>&1 | tr -s ' ')"

  log "--- 4) overlay on /system/bin ---"
  mount -t overlay overlay -o "lowerdir=/system/bin,upperdir=$MNT/upper,workdir=$MNT/work" /system/bin 2>>"$OUT"
  ORC=$?
  log "overlay rc=$ORC"
  grep " /system/bin " /proc/mounts >>"$OUT" 2>&1

  log "--- 5) 验证 ---"
  log "su: $(ls -l /system/bin/su 2>&1 | tr -s ' ')"
  log "PATH 解析 which su -> [$(command -v su 2>&1)]"
  log "lower 抽查: $(ls /system/bin/am /system/bin/id /system/bin/sh /system/bin/toybox 2>&1 | tr '\n' '|')"
else
  log "! 无空闲 loop，放弃"
fi
log "--- dmesg overlay 尾 ---"
dmesg 2>/dev/null | grep -iE "overlay|ext4" | tail -6 >>"$OUT"
echo "===== DONE =====" >> "$OUT"
