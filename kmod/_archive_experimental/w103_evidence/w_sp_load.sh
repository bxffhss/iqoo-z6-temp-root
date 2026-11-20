#!/system/bin/sh
# w_sp_load.sh — rc76 集成装载面真发腿（uid=0 via @sushd）
# 目标：交真机当前策略镜像 → ARM → GO，触发候选 ko 的 ld_go()→security_load_policy；
#       用 /sys/fs/selinux/status 的 policyload(偏移8, u32 小端) 在 GO 前后变化作为 ko 无关的地面真值，
#       并尽量读 ko 的 sysfs 参数(ld_load_rc/ld_why/ld_armed/ld_sym_rc/...)作为补充读数。
OUT=/data/local/tmp/sp_load_out.txt
P=/data/local/tmp/live_pol.bin
: > "$OUT"
log(){ echo "$*" >> "$OUT"; }

# 读数：status 文件偏移 8 处的 policyload（u32，小端）
read_policyload(){
  od -An -t d4 -j 8 -N 4 /sys/fs/selinux/status 2>/dev/null | tr -d ' \t\n'
}

log "=== T0 policyload_before ==="
PB=$(read_policyload); log "policyload_before=$PB"

log "=== T1 读活策略到文件（uid=0 可访问 /sys/fs/selinux/policy）==="
cat /sys/fs/selinux/policy > "$P" 2>/dev/null
SZ=$(wc -c < "$P" 2>/dev/null | tr -d ' \t')
log "policy_file_size=$SZ"

log "=== T2 交图：流式写入 /proc/ksu_sepol_img ==="
dd if="$P" of=/proc/ksu_sepol_img bs=65536 2>>"$OUT"
log "dd_rc=$?"

log "=== T3 ARM 0（让 ko 读活策略、记 ld_arm_live）==="
echo "ARM 0" > /proc/ksu_sepol_ctl 2>/dev/null
L=$(cat /sys/module/kernelsu/parameters/ld_arm_live 2>/dev/null | tr -d '\r')
log "ld_arm_live=$L"
if [ -z "$L" ]; then
  log "SYSFS_PARAMS_UNAVAILABLE=1  (arm 握手需 PC 侧算 FNV，本腿不 GO；已留 policy 文件)"
  exit 7
fi

log "=== T4 ARM <live_fnv> ==="
echo "ARM $L" > /proc/ksu_sepol_ctl 2>/dev/null
ARMED=$(cat /sys/module/kernelsu/parameters/ld_armed 2>/dev/null | tr -d '\r')
log "ld_armed_after_arm=$ARMED"

log "=== T5 GO（触发 ld_go()→security_load_policy）==="
echo "GO" > /proc/ksu_sepol_ctl 2>/dev/null

log "=== T6 证据 ==="
PA=$(read_policyload); log "policyload_after=$PA"
for p in ld_load_rc ld_why ld_armed ld_sym_rc ld_pre_sum ld_post_sum ld_pre_len ld_post_len ld_img_len ld_writes ld_fault ld_key ld_cap sp_arm ld_proc ld_seq; do
  v=$(cat /sys/module/kernelsu/parameters/$p 2>/dev/null | tr -d '\r')
  log "$p=$v"
done
log "=== DONE ==="
exit 0
