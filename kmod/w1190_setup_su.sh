#!/system/bin/sh
# w1190：给 /system/bin 挂 overlay，只新增一个 su（= 我们编的 ksu_su），复刻 ksud 开机动作。
# 安全设计：只增不删；失败自动 umount；toybox 预拷到 /data/local/tmp 以便 /system/bin 失效时仍能回退。
OUT=/data/local/tmp/w1190_setup_su.out
: > "$OUT"
log(){ echo "$@" >> "$OUT"; }

log "=== root $(id) up=$(cut -d' ' -f1 /proc/uptime)s ==="

log "--- [0] 前置 ---"
log "getenforce=$(getenforce)"
if grep -q overlay /proc/filesystems; then log "overlay: 支持"; else log "overlay: 不支持"; fi
grep " /system " /proc/mounts >> "$OUT"
grep -E " /product | /vendor " /proc/mounts >> "$OUT"
log "which su(前) -> [$(command -v su 2>&1)]"

# 回退工具：先把 toybox 拷到可写处，避免 overlay 异常时没 umount 可用
if [ ! -x /data/local/tmp/toybox ]; then
  cp /system/bin/toybox /data/local/tmp/toybox 2>>"$OUT" && chmod 0755 /data/local/tmp/toybox
fi
log "toybox 备份 -> $(ls -l /data/local/tmp/toybox 2>&1 | tr -s ' ')"

if [ -e /system/bin/su ] || grep -q " /system/bin " /proc/mounts; then
  log "! /system/bin/su 已存在或 /system/bin 已挂载 ⇒ 跳过 setup"
else
  UP=/data/local/tmp/ovl_sysbin_upper
  WK=/data/local/tmp/ovl_sysbin_work
  rm -rf "$UP" "$WK" 2>/dev/null
  mkdir -p "$UP" "$WK" || log "! mkdir 失败"
  cp /data/local/tmp/ksu_su "$UP/su" || log "! cp 失败"
  chown 0:0 "$UP/su" 2>>"$OUT"
  chmod 0755 "$UP/su" 2>>"$OUT"
  log "--- [1] upper 就绪 ---"
  ls -l "$UP/su" >> "$OUT" 2>&1
  md5sum "$UP/su" >> "$OUT" 2>&1

  log "--- [2] mount overlay on /system/bin ---"
  mount -t overlay overlay -o "lowerdir=/system/bin,upperdir=$UP,workdir=$WK" /system/bin 2>>"$OUT"
  MRC=$?
  log "mount rc=$MRC"
  grep " /system/bin " /proc/mounts >> "$OUT" 2>&1

  # 硬保护：只读判据（纯 builtin），坏了立刻回退
  if [ -x /system/bin/sh ] && [ -x /system/bin/id ] && [ -e /system/bin/su ]; then
    log "守卫: /system/bin/sh|id|su 均可见 -> OK"
  else
    log "守卫: 结构异常 -> 立刻 umount"
    /data/local/tmp/toybox umount /system/bin 2>>"$OUT"
    log "umount rc=$?"
  fi
fi

log "--- [3] 可见性（PATH 解析）---"
log "which su(后) -> [$(command -v su 2>&1)]"
ls -l /system/bin/su >> "$OUT" 2>&1
log "lower 抽查: $(ls /system/bin/sh /system/bin/id /system/bin/toybox 2>&1 | tr '\n' '|')"
echo "===== DONE =====" >> "$OUT"
