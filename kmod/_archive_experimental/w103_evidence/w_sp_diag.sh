#!/system/bin/sh
# w_sp_diag.sh — 以 root(@sushd) 读出候选 ko 的 sysfs 参数，定位 GO 没让 policyload +1 的原因。
OUT=/data/local/tmp/sp_diag_out.txt
: > "$OUT"
log(){ echo "$*" >> "$OUT"; }

log "=== /sys/module/kernelsu/ 存在性 ==="
ls -ld /sys/module/kernelsu 2>&1
log "=== parameters 目录 ==="
ls -la /sys/module/kernelsu/parameters/ 2>&1

log "=== 逐参数读数（root 可读则出值，不可读则空）==="
for p in sp_arm sp_verbose ld_key ld_cap ld_armed ld_arm_live ld_arm_want ld_why ld_load_rc ld_sym_rc ld_pre_sum ld_post_sum ld_pre_len ld_post_len ld_img_len ld_img_sum ld_writes ld_fault ld_seq ld_proc; do
  v=$(cat /sys/module/kernelsu/parameters/$p 2>/dev/null | tr -d '\r')
  log "$p=[$v]"
done

log "=== /proc/ksu_sepol 审计节点（read）==="
cat /proc/ksu_sepol 2>/dev/null | head -40 >> "$OUT"

log "=== DONE ==="
exit 0
