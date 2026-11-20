#!/system/bin/sh
# w_sp_diag2.sh — 非破坏诊断：定位 GO 没让 policyload +1 的真因
OUT=/data/local/tmp/sp_diag2_out.txt
: > "$OUT"
log(){ echo "$*" >> "$OUT"; }

log "=== kallsyms：装载/读策略/状态 三个符号在不在 ==="
for s in security_load_policy security_read_policy selinux_state; do
  hit=$(grep -w "$s" /proc/kallsyms 2>/dev/null | head -1)
  log "$s => [${hit:-NONE}]"
done
log "kptr_restrict=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)"

log "=== 活策略现在读一份，md5（与 Leg1 拉的 live_pol_1108.bin 比对，证 FNV 没过期）==="
cat /sys/fs/selinux/policy > /data/local/tmp/live_now.bin 2>/dev/null
log "live_now_md5=$(md5sum /data/local/tmp/live_now.bin 2>/dev/null | cut -d' ' -f1)  size=$(wc -c < /data/local/tmp/live_now.bin 2>/dev/null | tr -d ' ')"

log "=== 回读 ko 缓冲 /proc/ksu_sepol_img，md5（证图没被污染/半截）==="
cat /proc/ksu_sepol_img > /data/local/tmp/img_rb.bin 2>/dev/null
log "img_rb_md5=$(md5sum /data/local/tmp/img_rb.bin 2>/dev/null | cut -d' ' -f1)  size=$(wc -c < /data/local/tmp/img_rb.bin 2>/dev/null | tr -d ' ')"

log "=== dmesg 里 ksu_sepol 相关（load 失败会有 pr_warn，与 verbose 无关）==="
dmesg 2>/dev/null | grep -i ksu_sepol | tail -30 >> "$OUT"

log "=== DONE ==="
exit 0
