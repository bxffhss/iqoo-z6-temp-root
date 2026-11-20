#!/system/bin/sh
# w433_slide_solve.sh — 一键包的设备侧 slide 求解「驱动」：把 perfips 的原始输出喂给 ksu_slide.awk。
#
# ★这一版是重写。第一版（今天 22:5x）我按"perfips 那行 `k <hex>` 是 jiffies、
#   候选窗口 = 本 boot 开机时刻前后"来写，还把 boot_id 当成算窗口的输入。
#   读完 analysis/slide_pc.py 全文才发现那句是错的：PC 侧从头到尾**没用过时间**，
#   候选窗口是从**样本地址簇**本身推出来的
#       lo = (簇末地址 - link_etext) 落到 2MB 再退 6 档
#       hi = (簇首地址 - link_text)  落到 2MB 再进 6 档
#   判据 = 正对照函数窗口命中数。⇒ 求解器不需要 root、不需要时间、也不需要 boot_id
#   （boot_id 仍然留作**缓存键**，那是另一件事）。教训见记忆"抄算法前先读算法本体"。
#
# 用法: sh w433_slide_solve.sh <perfips原始输出> <slide_ctl.txt> <ksu_slide.awk>
#   stdout 原样透传求解器（最后一行是 `SLIDE <hex>` 或 `NOSLIDE <原因>`），退出码同求解器。
#   调用方只该信 `^SLIDE ` 那一行；NOSLIDE 一律算失败，不许猜。
set -u

RAW=${1:-}
CTL=${2:-}
AWKF=${3:-}
die() { echo "NOSLIDE $*"; exit 2; }

[ -n "$RAW" ] && [ -f "$RAW" ] || die "采样文件不存在 [$RAW]"
[ -n "$CTL" ] && [ -s "$CTL" ] || die "正对照表不存在或为空 [$CTL]"
[ -n "$AWKF" ] && [ -s "$AWKF" ] || die "求解器 awk 不存在或为空 [$AWKF]"
command -v awk >/dev/null 2>&1 || die "这台设备上没有 awk"

# ── 常量从表头取，脚本里**不重写**一遍 0xffffffc0…（重写就会分叉：换 SPL 后表变了、脚本没变）
#    ★表头里 link_text/link_etext 是 16 位 hex、step_dec 是**十进制**字节数(2097152)：
#      真机第一跑把 hex 的 200000 当十进制喂进去，步长就变成 0x30d40 ⇒ 字段名里带进制。
LINE=$(grep -a -m1 '^# CONSTS ' "$CTL")
[ -n "$LINE" ] || die "slide_ctl.txt 缺 '# CONSTS link_text=… link_etext=… step_dec=…' 那行表头"
LT=${LINE#*link_text=}; LT=${LT%% *}
ET=${LINE#*link_etext=}; ET=${ET%% *}
ST=${LINE#*step_dec=};  ST=${ST%% *}
case "$LT$ET" in *[!0-9a-f]*) die "表头常量含非 hex 字符 [$LT/$ET]" ;; esac
[ ${#LT} = 16 ] && [ ${#ET} = 16 ] || die "表头常量不是 16 位 hex [$LT/$ET]"
case "$ST" in ''|*[!0-9]*) die "step_dec 不是十进制 [$ST]" ;; esac
[ "$ST" -gt 0 ] 2>/dev/null || die "step_dec 必须 > 0 [$ST]"

# ── 取样本：perfips 打的是 `k <hex>`（也可能是裸 hex 行），一律取每行最后一个字段，
#    再要求整行正好是 16 位 hex ⇒ 时间戳/统计行/`N=1023` 这种自然被丢掉，
#    与 PC 侧那个 `([0-9a-f]{12,16})\s*$` + 高半区过滤同口径。──
SAMP="$RAW.samp"
LC_ALL=C awk '{print $NF}' "$RAW" | LC_ALL=C grep -aE '^[0-9a-f]{16}$' | LC_ALL=C sort -u > "$SAMP"
NS=$(wc -l < "$SAMP" | tr -d ' ')
[ "${NS:-0}" -ge 50 ] || die "16 位 hex 的样本只有 ${NS:-0} 个(<50)⇒ 采样没抓到东西，不猜"

# ── 求解：主簇/窗口/命中全在 awk 里（那里做 64 位地址的精确比较）。──
awk -v link_text="$LT" -v link_etext="$ET" -v step_dec="$ST" -f "$AWKF" "$CTL" "$SAMP"
R=$?
rm -f "$SAMP"
exit $R
