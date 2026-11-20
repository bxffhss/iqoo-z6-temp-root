#!/system/bin/sh
OUT=/data/local/tmp/w1194_su_ab.out
: > "$OUT"
log(){ echo "$@" >> "$OUT"; }
log "=== root=$(id -u) up=$(cut -d' ' -f1 /proc/uptime)s ==="
log "which su -> [$(command -v su)]"
log "su 文件: $(ls -l /system/bin/su | tr -s ' ')"

log "--- [A] 10667 termux（本轮 setprof 已授权）期望 uid=0 ---"
/data/local/tmp/asuid 10667 /system/bin/su -c id >>"$OUT" 2>&1; log "rc=$?"

log "--- [B] 10349 Scene（未授权）期望被拒 ---"
/data/local/tmp/asuid 10349 /system/bin/su -c id >>"$OUT" 2>&1; log "rc=$?"

log "--- [C] 10104 官方 Manager appid ---"
/data/local/tmp/asuid 10104 /system/bin/su -c id >>"$OUT" 2>&1; log "rc=$?"

log "--- [D] 授权表现状 ---"
/data/local/tmp/asuid 10104 /data/local/tmp/ksuctl88 granted 10667 2>&1 | grep -E "UID_GRANTED_ROOT" >>"$OUT"
/data/local/tmp/asuid 10104 /data/local/tmp/ksuctl88 granted 10342 2>&1 | grep -E "UID_GRANTED_ROOT" >>"$OUT"
/data/local/tmp/ksuctl88 granted 10349 2>&1 | grep -E "UID_GRANTED_ROOT" >>"$OUT"

log "--- [E] 运行期 setprof 授权 10349(Scene) 后再试 su ---"
/data/local/tmp/asuid 10104 /data/local/tmp/ksuctl88 setprof 10349 com.bbk.scene.launcher.theme u:r:shell:s0 2>&1 | grep -E "SET_APP_PROFILE|rc=" >>"$OUT"
/data/local/tmp/asuid 10349 /system/bin/su -c id >>"$OUT" 2>&1; log "rc=$?"

log "--- [F] 撤销 10349 再次确认（负对照闭环）---"
/data/local/tmp/asuid 10104 /data/local/tmp/ksuctl88 setprof 10349 - - 2>&1 | grep -E "SET_APP_PROFILE|rc=" >>"$OUT"
/data/local/tmp/asuid 10349 /system/bin/su -c id >>"$OUT" 2>&1; log "rc=$?"
echo "===== DONE =====" >> "$OUT"
