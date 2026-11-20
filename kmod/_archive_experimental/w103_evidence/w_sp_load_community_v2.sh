#!/system/bin/sh
# w_sp_load_community_v2.sh — 目标③ 装面腿（11-08，§6.573）
#   ★与 w_sp_load_community.sh 的差别：原腿要 PC 侧传 FNV_CURRENT_LIVE 参数，
#     而 go.sh 的 LEG1 只派一支不带参的腿、窗口外 @sushd 又无效(§6.570)
#     ⇒ 本腿把「现场定 FNV」做进腿内：root 拉本窗活策略 → md5sum → 已知 base 择 FNV，
#       未知 base 一律 fail-closed 不装（不许拿别的 base 的图整体替换活策略）。
#   门语义(§6.569)：armed_sum 写 FNV(当前活策略)，GO 当下 live 未变则放行，
#       装的是 /proc/ksu_sepol_img 里的「社区增量图」(图 != live，门不比图)。
#   零削弱前提(本轮 0 枪已证)：造图 base 84fbaface… 与厂商原始 282a6861… 的
#       dump 规则行逐字相同(72813 行, PATCH_ADDED=0/REMOVED=0)，故装图只增 9 条。
#   FNV 基数 1469598103934665603 = ko 实现(非标准；标准 14695981039346656037 会 ARMMISMATCH)。
#   policyload 在 /sys/fs/selinux/status 偏移 12 的 u32（专用 policyload 节点本机空）。
OUT=/data/local/tmp/sp_comm_out.txt
: > "$OUT"
log(){ echo "$*" >> "$OUT"; }
END(){ log "=== END up=$(cut -d' ' -f1 /proc/uptime) ==="; }
read_pl(){ od -An -t d4 -j 12 -N 4 /sys/fs/selinux/status 2>/dev/null | tr -d ' \t\n'; }
md5of(){ set -- $(md5sum "$1" 2>/dev/null); echo "$1"; }

log "=== w_sp_load_community_v2 uid=$(id -u) up=$(cut -d' ' -f1 /proc/uptime) ==="

# ---- 前置 1：装载面三节点（sp_arm=1 建）必须在 ----
for n in /proc/ksu_sepol_img /proc/ksu_sepol_ctl /proc/ksu_sepol; do
    [ -e "$n" ] || { log "FATAL 缺装载节点 $n ⇒ 不装"; END; exit 6; }
done
log "LOAD_NODES=3 ok"

# ---- 前置 2：增量图必须在，且 md5 = 本机登记值 ----
IMG=/data/local/tmp/community_new.pol
[ -f "$IMG" ] || { log "FATAL 缺图 $IMG ⇒ 不装"; END; exit 3; }
set -- $(md5sum "$IMG"); IMG_MD5=$1
log "IMG_MD5=$IMG_MD5 size=$(wc -c < "$IMG")"
[ "$IMG_MD5" = d1eb00204a8b6e9686ea137471f94f28 ] || { log "FATAL 图 md5 与登记不符 ⇒ 不装"; END; exit 4; }

# ---- 现场拉本窗活策略（出厂态 shell 读不到，root 腿才读得到）----
cat /sys/fs/selinux/policy > /data/local/tmp/live_comm.pol 2>/dev/null
LRC=$?
set -- $(md5sum /data/local/tmp/live_comm.pol 2>/dev/null); LIVE_MD5=$1
log "LIVE_PULL_RC=$LRC LIVE_MD5=$LIVE_MD5 LIVE_SIZE=$(wc -c < /data/local/tmp/live_comm.pol)"
[ "$LRC" = 0 ] && [ -n "$LIVE_MD5" ] || { log "FATAL 拉不到本窗活策略 ⇒ 不装"; END; exit 7; }

# ---- 按 md5 择 FNV；未知 base fail-closed ----
case "$LIVE_MD5" in
    282a68611a2f36321a153fc0102f9ca0) FNV=5457979107816203493; log "BASE=orig 厂商原始策略";;
    84fbaface5757e2692443728bd8ff8cf) FNV=804402997947390401; log "BASE=patched 补丁后策略";;
    *) log "FATAL 未知 base md5=$LIVE_MD5 ⇒ fail-closed 不装(不许拿别的 base 的图硬替换)"; END; exit 5;;
esac
log "FNV_CURRENT_LIVE=$FNV"

# ---- ★双读一致闸(§6.569 教训)：ARM 前再读一次活策略，md5 变了说明中间有人 load
#      (Manager 独立打 sepolicy 补丁) ⇒ FNV 已过期，fail-closed 不装，不许 ARMMISMATCH 蒙混 ----
cat /sys/fs/selinux/policy > /data/local/tmp/live_comm_2.pol 2>/dev/null
set -- $(md5sum /data/local/tmp/live_comm_2.pol 2>/dev/null); LIVE_MD5_2=$1
log "LIVE_MD5_2=$LIVE_MD5_2"
[ "$LIVE_MD5_2" = "$LIVE_MD5" ] || { log "FATAL 活策略在腿内变了 ($LIVE_MD5 -> $LIVE_MD5_2) ⇒ FNV 过期，不装"; END; exit 8; }
log "LIVE_STABLE=1 (两次现读逐字一致，FNV 有效)"

# ---- 装载门：RESET → 交图 → ARM → GO ----
PB=$(read_pl); log "policyload_before=$PB"
echo RESET > /proc/ksu_sepol_ctl 2>/dev/null; log "reset_rc=$?"
dd if="$IMG" of=/proc/ksu_sepol_img bs=65536 2>>"$OUT"; log "dd_rc=$?"
echo "ARM $FNV" > /proc/ksu_sepol_ctl 2>/dev/null; log "arm_rc=$?"
echo GO > /proc/ksu_sepol_ctl 2>/dev/null; log "go_rc=$?"

PA=$(read_pl); log "policyload_after=$PA"
log "status_full=$(od -An -t d4 -j 0 -N 20 /sys/fs/selinux/status 2>/dev/null | tr -d '\n')"
log "enforce_now=$(cat /sys/fs/selinux/enforce 2>/dev/null)"
if [ "$PA" = "$((PB+1))" ]; then log "POLICYLOAD_DELTA_OK=1"; else log "POLICYLOAD_DELTA_OK=0 (期望 +1；0 表示门未放行，不许读成通过)"; fi

# ---- 重导出运行期策略，供 PC 侧零削弱差分（最终判据）----
cat /sys/fs/selinux/policy > /data/local/tmp/community_post.pol 2>/dev/null; log "post_rc=$?"
set -- $(md5sum /data/local/tmp/community_post.pol 2>/dev/null); log "POST_MD5=$1 POST_SIZE=$(wc -c < /data/local/tmp/community_post.pol)"
END
exit 0
