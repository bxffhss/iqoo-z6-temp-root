#!/system/bin/sh
# w_sp_load2.sh — rc76 集成装载面真发腿·第二腿（uid=0 via @sushd）
# 前置：w_sp_load.sh 已把活策略镜像流式写入 /proc/ksu_sepol_img（dd_rc=0，缓冲保留在 ko 内核内存，未 RESET）。
# 本腿只做 ARM <PC 侧算好的 FNV> ＋ GO，用 /sys/fs/selinux/status 偏移8的 policyload(u32 小端)
# 在 GO 前后变化作为 ko 无关的地面真值，证明 ld_go()→security_load_policy 真被调用且成功。
OUT=/data/local/tmp/sp_load2_out.txt
: > "$OUT"
log(){ echo "$*" >> "$OUT"; }
read_policyload(){
  od -An -t d4 -j 8 -N 4 /sys/fs/selinux/status 2>/dev/null | tr -d ' \t\n'
}

FNV=5457979107816203493   # PC 侧 FNV-1a64(live_pol_1108.bin, 1356948 B) = 0x4bbea314b8e364e5

log "=== T0 policyload_before ==="
PB=$(read_policyload); log "policyload_before=$PB"

log "=== T1 ARM $FNV（ko 重读活策略、算 FNV、armed=(live==want)?1:-1）==="
echo "ARM $FNV" > /proc/ksu_sepol_ctl 2>/dev/null
log "arm_write_rc=$?"   # 0=写成功(即 ld_live 读活策略没红)；armed 内部状态不可经 sysfs 读，靠 policyload 判定

log "=== T2 GO（ld_go()：重读活策略→w1161_gate→p_ld_load=security_load_policy）==="
echo "GO" > /proc/ksu_sepol_ctl 2>/dev/null
log "go_write_rc=$?"

log "=== T3 policyload_after（ko 无关地面真值：成功 load 必 +1）==="
PA=$(read_policyload); log "policyload_after=$PA"

log "=== T4 enforce / 窗口态 ==="
log "enforce=$(cat /sys/fs/selinux/enforce 2>/dev/null)"
log "mod=$(grep -c kernelsu /proc/modules 2>/dev/null)"

log "=== DONE ==="
exit 0
