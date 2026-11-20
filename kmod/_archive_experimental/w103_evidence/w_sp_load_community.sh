#!/system/bin/sh
# w_sp_load_community.sh — 目标③ 端到端腿：把"社区模块 sepolicy.rule 增量图"经 rc76 候选集成装载门
#   真装进运行期策略，并留重导出件供 PC 侧零削弱差分。
#
# ★协议要点（与 w_sp_load3.sh 的唯一差别）：
#   w_sp_load3 交的是"当前活策略原图"(reload，FNV(图)==FNV(live) 自然相等)；
#   本腿交的是"当前活策略 + 社区规则"的增量图——图本身 != live，但**门不比图**。
#   门只校验 armed_sum(本腿 ARM 时写的值) == GO 时重读的当前活策略 FNV。
#   ⇒ 本腿 ARM 必须写 **FNV(当前活策略)**（不是 FNV(增量图)），GO 当下 live 未变 ⇒ 门放行 ⇒ 装增量图。
#   这正是 §6.569 那次"Manager 打补丁致 FNV 过期→ARMMISMATCH"的反面用法：那次是误用（图==live 却武装错值），
#   本腿是正确用法（图!=live，但武装的是 live 的 FNV，门只认 live 没被篡改）。
#
# 调用（由 fire() 以 uid=0 跑）：
#   sh w_sp_load_community.sh <FNV_CURRENT_LIVE> <DELTA_IMG_ON_DEVICE>
#   FNV_CURRENT_LIVE = PC 侧 FNV-1a64(当前活策略文件) 的十进制——必须来自本窗 pull 的那份 live.pol
#                      （Manager 在 insmod 后会给活策略打补丁，必须用打补丁后的 live.pol 算，否则 ARMMISMATCH）
#   DELTA_IMG_ON_DEVICE = 远端 w1104_delta delta <live.pol> new.pol <rules> 产出的完整可装载增量图路径
#
# 读数：policyload 在 selinux status 页偏移 12 的 u32（专用 /sys/fs/selinux/policyload 本机空）。
OUT=/data/local/tmp/sp_comm_out.txt
: > "$OUT"
log(){ echo "$*" >> "$OUT"; }
read_pl(){ od -An -t d4 -j 12 -N 4 /sys/fs/selinux/status 2>/dev/null | tr -d ' \t\n'; }

FNV=${1:-0}
IMG=${2:-/data/local/tmp/community_new.pol}
[ -n "$FNV" ] || { log "缺 FNV 参数"; exit 2; }
[ -f "$IMG" ] || { log "缺增量图 $IMG"; exit 3; }

log "=== P0 policyload(status@12) ==="
PB=$(read_pl); log "policyload_before=$PB"

log "=== RESET（清缓冲＋清武装）==="
echo "RESET" > /proc/ksu_sepol_ctl 2>/dev/null; log "reset_rc=$?"

log "=== 交社区增量图（RESET 后缓冲清空，dd 不会追加污染）==="
dd if="$IMG" of=/proc/ksu_sepol_img bs=65536 2>>"$OUT"; log "dd_rc=$?"

log "=== ARM $FNV（注意：写的是 FNV(当前活策略)，不是 FNV(增量图)；门只比 live）==="
echo "ARM $FNV" > /proc/ksu_sepol_ctl 2>/dev/null; log "arm_rc=$?"

log "=== GO（ld_go()→security_load_policy 装增量图）==="
echo "GO" > /proc/ksu_sepol_ctl 2>/dev/null; log "go_rc=$?"

log "=== P1 policyload(status@12) ==="
PA=$(read_pl); log "policyload_after=$PA"
log "status_full=$(od -An -t d4 -j 0 -N 20 /sys/fs/selinux/status 2>/dev/null | tr -d '\n')"
log "enforce_now=$(cat /sys/fs/selinux/enforce 2>/dev/null)"

# ★重导出运行期策略，供 PC 侧 w1116 式零削弱差分证"社区规则确实在"
log "=== 重导出活策略（PC 侧差分用）==="
cat /sys/fs/selinux/policy > /data/local/tmp/community_post.pol 2>/dev/null; log "post_rc=$?"

# ★独立证人：policyload 必须 +1（区间内只有这一条 GO 在跑），否则门没真放行到装载
if [ "$PA" = "$((PB+1))" ]; then
	log "POLICYLOAD_DELTA_OK=1"
else
	log "POLICYLOAD_DELTA_OK=0 (期望 +1)"
fi
log "=== DONE ==="
exit 0
