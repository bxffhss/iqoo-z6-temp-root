#!/system/bin/sh
# w_sp_load3.sh — 干净复测：用"当前"活策略的 FNV 武装，证 ko 集成装载面真调 security_load_policy。
# 背景：w_sp_load2 用 Leg1 拉的旧(base)策略 FNV 武装，但 Manager 在之间给活策略打了 sepolicy 补丁，
#       导致活的 != 武装值 ⇒ ARMMISMATCH ⇒ 没装。本腿改用当前活策略(live_now.bin)的 FNV 重来。
OUT=/data/local/tmp/sp_load3_out.txt
: > "$OUT"
log(){ echo "$*" >> "$OUT"; }
# policyload 在 selinux status 页偏移 12 的 u32（专用 /sys/fs/selinux/policyload 本机空，改用此）
read_pl(){ od -An -t d4 -j 12 -N 4 /sys/fs/selinux/status 2>/dev/null | tr -d ' \t\n'; }

L=/data/local/tmp/live_now.bin
FNV=804402997947390401   # PC 侧 FNV-1a64(live_now_1108.bin, 1356948 B) = 0xb29d043c4e9d9c1

log "=== P0 policyload(status@12) ==="
PB=$(read_pl); log "policyload_before=$PB"

log "=== RESET（清缓冲＋清武装）==="
echo "RESET" > /proc/ksu_sepol_ctl 2>/dev/null; log "reset_rc=$?"

log "=== 交当前活策略镜像（RESET 后缓冲清空，dd 不会追加污染）==="
dd if="$L" of=/proc/ksu_sepol_img bs=65536 2>>"$OUT"; log "dd_rc=$?"

log "=== ARM $FNV（ko 重读当前活策略、算 FNV、armed=(live==want)?1:-1）==="
echo "ARM $FNV" > /proc/ksu_sepol_ctl 2>/dev/null; log "arm_rc=$?"

log "=== GO（ld_go()→security_load_policy）==="
echo "GO" > /proc/ksu_sepol_ctl 2>/dev/null; log "go_rc=$?"

log "=== P1 policyload(status@12) ==="
PA=$(read_pl); log "policyload_after=$PA"
log "status_full=$(od -An -t d4 -j 0 -N 20 /sys/fs/selinux/status 2>/dev/null | tr -d '\n')"
log "enforce_now=$(cat /sys/fs/selinux/enforce 2>/dev/null)"
log "=== DONE ==="
exit 0
