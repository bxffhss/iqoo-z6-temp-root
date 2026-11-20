#!/system/bin/sh
# w889: precise per-label ladder for our root child (uid=0, u:r:shell:s0)
echo "W889 BEGIN up=$(cut -d' ' -f1 /proc/uptime) CTX=$(cat /proc/self/attr/current 2>&1)"
t() {
  P="$1"
  L=$(stat -c %C "$P" 2>&1)
  if ls "$P" >/dev/null 2>&1; then R="LS_OK"; else R="LS_DENY"; fi
  if cat "$P" >/dev/null 2>&1; then C="CAT_OK"; else C="CAT_no"; fi
  printf '  %-34s %-46s %s %s\n' "$P" "$L" "$R" "$C"
}
t /data/data
t /data/data/com.termux
t /data/data/com.termux/files
t /data/data/bin.mt.plus.canary
t /data/data/com.omarea.vtools
t /data/local
t /data/local/tmp
t /data/adb
t /data/system
t /data/system/packages.list
t /data/anr
t /data/misc
t /sdcard/Android
t /sdcard/Android/data
t /product/bin
t /system/bin
t /data/adb/ksu/.allowlist
echo "W889 END up=$(cut -d' ' -f1 /proc/uptime)"
