#!/system/bin/sh
# w1142_polload_leg.sh —— #237(B′) 的设备侧腿：把一份"PC 算好的完整策略图"交给 z6polload 那条模块侧入口，
#   并把**装载前后**的读数逐格落到自己的证件文件里(每步 sync：万一装载把机器打死，已经写下的格还在)。
# ★这一腿**不碰 /sys/fs/selinux/load**(它走的是模块里那句 security_load_policy)，也**不翻执法**。
# ★mksh 的坑(本仓一手)：`echo` 不看 write 的返回码 ⇒ 写命令一律**读回参数**当证人，不信 echo 的 rc；
#   写图用 `dd`(它看返回码)；节拍只用 `sleep`。
# ★§293 那条纪律：被测自己带的开关，调用方**显式传值＋把参数本身回抄进证件**——
#   `pl_key`/`pl_cap`/`pl_test_ctx` 三条都印 `pre_*`，且 `pre_key` 不等于预期就当场停(传进去没进去不许猜)。
# 必须给的环境变量(由 PC 侧链提供，缺一个就停——"参数没传到"就是空枪的形状)：
#   IMG=<设备上已 push 的整图路径>  ARMBASE=<十进制 FNV-1a64，来自"这一刻之前的活策略">
#   可选：CTX=<装载后才该解得开的上下文> CTRL=<现成正对照标签> KO=<探针.ko> OUT=<证件路径>
#         KEEP=1(默认 0＝跑完 rmmod 探针；★装载成功的图**不会**被 rmmod 回滚)
set -u
# ★参数从**设备侧一个小文件**里取：go.sh 是 `fire "@sushd:<腿>"` 派腿的，PC 侧的环境变量过不去
#   (94/95 发那格 expect.txt 同一个道理)。文件里没有的键，退到下面的默认值。
# ★这里**不用 `. "$CTL"`**：那等于让一个 uid 2000 可写的 0666 文件以 root 身份执行代码。
#   只按"键=值"取字符串(getk)，取到的值只进带引号的展开 ⇒ 少一条自己给自己开的后门。
P=${OUT_DIR:-/data/local/tmp/w1142}
CTL=${CTL:-$P/ctl.txt}
getk() { sed -n "s/^$1=//p" "$CTL" 2>/dev/null | tail -1; }
OUT=${OUT:-$(getk OUT)}; OUT=${OUT:-$P/leg.out}
ERRF=$P/leg.err
KO=${KO:-$(getk KO)};        KO=${KO:-$P/z6polload.ko}
IMG=${IMG:-$(getk IMG)}
ARMBASE=${ARMBASE:-$(getk ARMBASE)}
CTX=${CTX:-$(getk CTX)};     CTX=${CTX:-u:object_r:z6_probe_file:s0}
CTRL=${CTRL:-$(getk CTRL)};  CTRL=${CTRL:-u:object_r:shell_data_file:s0}
KEYDEC=${KEYDEC:-$(getk KEYDEC)}; KEYDEC=${KEYDEC:-1347374148}	# = 0x504F4C44 = 'POLD'
CAP=${CAP:-$(getk CAP)};     CAP=${CAP:-8388608}
KEEP=${KEEP:-$(getk KEEP)};  KEEP=${KEEP:-0}
IMG=${IMG:?IMG 不给就停：这一腿没有图就没有被测}
ARMBASE=${ARMBASE:?ARMBASE 不给就停：没有武装值，第二道闸结构上过不去}
PM=/sys/module/z6polload/parameters
POLF=/proc/w1140_pol
CTLF=/proc/w1140_ctl

mkdir -p "$P" 2>/dev/null
: >"$ERRF" 2>/dev/null
: >"$OUT" 2>>"$ERRF"
say() { printf '%s\n' "$*" >>"$OUT" 2>>"$ERRF"; sync; }
rd() { cat "$1" 2>>"$ERRF"; }
up() { cut -d. -f1 /proc/uptime 2>/dev/null; }
modcnt() { grep -c '^z6polload ' /proc/modules 2>/dev/null; }

say "LEG_BEGIN up=$(up) boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
say "LEG enf=$(rd /sys/fs/selinux/enforce) img=$IMG img_md5=$(md5sum "$IMG" 2>/dev/null) img_bytes=$(wc -c <"$IMG" 2>/dev/null)"
say "LEG ctl_path=$CTL ctl_exists=$([ -f "$CTL" ] && echo 1 || echo 0) ctl_raw=$(tr '\n' '|' <"$CTL" 2>/dev/null)"
say "LEG arm=$ARMBASE ctx=$CTX ctrl=$CTRL keydec=$KEYDEC cap=$CAP ko=$KO ko_md5=$(md5sum "$KO" 2>/dev/null)"

# 0) 两件都要在(ko 的身份 md5 由链给，腿只印不判)
[ -f "$KO" ] || { say "LEG_FAIL=ko 不在 ⇒ 不试"; exit 1; }
[ -f "$IMG" ] || { say "LEG_FAIL=img 不在 ⇒ 不试"; exit 1; }

# 1) 装载前的活策略先自己导出一次：腿这份 pull 出去算的 FNV，与模块内核侧算的 pl_pre_sum 是两条独立路径
dd if=/sys/fs/selinux/policy of="$P/pol.before" bs=4096 2>>"$ERRF"
say "LEG export_rc=$? before_md5=$(md5sum "$P/pol.before" 2>/dev/null) before_bytes=$(wc -c <"$P/pol.before" 2>/dev/null)"

# 2) insmod(带钥匙)。裸 insmod 不带 pl_key ⇒ 结构上进不到装载；这里显式传值并回抄
insmod "$KO" pl_key="$KEYDEC" pl_cap="$CAP" pl_test_ctx="$CTX" pl_ctrl_ctx="$CTRL" 2>"$ERRF"
say "LEG insmod_rc=$? insmod_err=$(head -3 "$ERRF" 2>/dev/null)"
say "LEG mod_seen=$(modcnt)"
[ -d "$PM" ] || { say "LEG_FAIL=没有 $PM ⇒ 探针没进来，后面全是空读数"; exit 1; }
for k in abi sym_rc proc key cap why seq armed test_ctx ctrl_ctx; do
  say "LEG pre_$k=$(rd "$PM/pl_$k")"
done
if [ "$(rd $PM/pl_key)" != "$KEYDEC" ]; then
  say "LEG_FAIL=pl_key 回抄不等于传进去的值 ⇒ 停(参数没生效＝这一发没有被测)"
  exit 1
fi
say "LEG GATE1_key_ok=$(rd $PM/pl_key)"

# 3) 武装(第二道闸)。★不信 echo 的 rc：写没写进去看 `pl_arm_want`，核没核上看 `pl_armed`
echo "ARM $ARMBASE" >"$CTLF" 2>>"$ERRF"
sleep 1
say "LEG ARM_written=$ARMBASE arm_want=$(rd $PM/pl_arm_want) arm_live=$(rd $PM/pl_arm_live) armed=$(rd $PM/pl_armed) seq=$(rd $PM/pl_seq)"

# 4) 交图。★用 dd 不用 cat——dd 看 write 的返回码
dd if="$IMG" of="$POLF" bs=65536 2>>"$ERRF"
say "LEG stage_rc=$? stage_err=$(head -2 "$ERRF" 2>/dev/null)"
# ★键名一律带 `stage_` 前缀：`why`/`img_len` 这种裸名会与 `pre_why`/`post_why` 撞，链里 `sed 's/.*why=//'`
#   会取到**第一条**匹配行＝一个完全不同阶段的数(例 222 那一族的变体)。
say "LEG stage stage_img_len=$(rd $PM/pl_img_len) stage_img_sum=$(rd $PM/pl_img_sum) stage_img_wvers=$(rd $PM/pl_img_wvers) stage_writes=$(rd $PM/pl_writes) stage_why=$(rd $PM/pl_why)"
# ★暂存字节原样读回再比 md5：证明"落进内核那块缓冲的字节＝我发的那份"，不是"我以为发出去了"
dd if="$POLF" of="$P/pol.staged" bs=65536 2>>"$ERRF"
say "LEG staged_rc=$? staged_md5=$(md5sum "$P/pol.staged" 2>/dev/null) staged_bytes=$(wc -c <"$P/pol.staged" 2>/dev/null) 期望_整行md5=$(md5sum "$IMG" 2>/dev/null) 期望_bytes=$(wc -c <"$IMG" 2>/dev/null)"

# 5) ★下令装载(第三道闸在这里合上：pre 那几格必须先写下来——装载可能把机器打死)
say "LEG GO_AT up=$(up) load_rc_before=$(rd $PM/pl_load_rc) why_before=$(rd $PM/pl_why)"
echo GO >"$CTLF" 2>>"$ERRF"
sleep 2
for k in why load_rc pre_len pre_sum post_len post_sum rc_pre rc_post kc_pre kc_post sid_pre sid_post ksid_pre ksid_post img_wvers img_sum writes seq armed; do
  say "LEG post_$k=$(rd "$PM/pl_$k")"
done

# 6) 装载之后再导一次活策略(甲尺的 PC 端)：与 post_sum 两条独立路径到同一批字节
dd if=/sys/fs/selinux/policy of="$P/pol.after" bs=4096 2>>"$ERRF"
say "LEG export2_rc=$? after_md5=$(md5sum "$P/pol.after" 2>/dev/null) after_bytes=$(wc -c <"$P/pol.after" 2>/dev/null)"
say "LEG staged_eq_live=$( [ "$(md5sum "$P/pol.after" 2>/dev/null | cut -d' ' -f1)" = "$(md5sum "$P/pol.staged" 2>/dev/null | cut -d' ' -f1)" ] && echo 1 || echo 0)"

# 7) 机器还活着的基本读数(不是判据，是"这一发有没有跑到收尾"的证人)
say "LEG alive enf=$(rd /sys/fs/selinux/enforce) mod=$(modcnt) up=$(up) ksu_mod=$(grep -c '^kernelsu ' /proc/modules 2>/dev/null)"
if [ "${KEEP:-0}" != 1 ]; then
  rmmod z6polload 2>"$ERRF"
  say "LEG rmmod_rc=$? rmmod_err=$(head -2 "$ERRF" 2>/dev/null) 参数目录还在=$([ -d "$PM" ] && echo 1 || echo 0)"
  say "LEG NOTE=rmmod 只摘探针，**不会**回滚已装上的策略(策略是内核的，不是模块的)"
fi
say "LEG_END up=$(up)"
