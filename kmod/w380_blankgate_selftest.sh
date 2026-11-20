#!/bin/bash
# w380_blankgate_selftest.sh —— 第 135 发那记"假空枪"的夹具自测。
#   ★判据不在这里抄一份：source kmod/blank_gate.sh —— 与 kmod/go.sh 用的是**同一个函数** ⇒ 改判据一定反映到这里。
#   ★再加一条**漂移闸**：go.sh 必须真的在用 blank_now 与 SAWPER 闩锁、且旧的"只看 [SEN]"谓词已消失；
#     否则"唯一真源"名存实亡(例 93：一次性脚本的正则必须搬进可复跑 checker；这里防的是同一个失效模式)。
#   ★反例格("不加就坏")保留：本地抄一份旧谓词 old_blank，证明旧规则在 135 当晚那一格确实会误判(例 88)。
set -u
cd "$(dirname "$0")/.." || exit 1
. kmod/blank_gate.sh
type blank_now >/dev/null 2>&1 || { echo '[x] kmod/blank_gate.sh 里没有 blank_now'; exit 1; }
old_blank() { [ -z "$3" ] && [ "$4" = "0" ]; }   # 旧规则：pr 不在 + 无 POST（`[SEN]` 在旧代码里当晚即为真）

fails=0
chk() { # $1=标题 $2=期望新 $3=期望旧 $4=sawper $5=enf $6=pr $7=post计数
    local t=$1 wn=$2 wo=$3 s=$4 e=$5 p=$6 q=$7 gn go
    if blank_now "$s" "$e" "$p" "$q"; then gn=空枪; else gn=继续等; fi
    if old_blank "$s" "$e" "$p" "$q"; then go=空枪; else go=继续等; fi
    [ "$gn" = "$wn" ] || { echo "  [x] $t ⇒ blank_now=[$gn] 期望[$wn]"; fails=$((fails + 1)); return; }
    [ "$go" = "$wo" ] || { echo "  [x] $t ⇒ 旧谓词=[$go] 期望[$wo](反例格失效)"; fails=$((fails + 1)); return; }
    echo "  ✓ $t ⇒ 新[$gn] 旧[$go]"
}
chk "135 当晚：翻转尚未发生"             继续等 空枪 0 Enforcing '' 0
chk "119 发那种真空枪：翻过且 enf 回跳"  空枪   空枪 1 Enforcing '' 0
chk "还在飞：enf 仍 Permissive"         继续等 空枪 1 Permissive '' 0
chk "post 已出现 ⇒ 该走判据⑥"           继续等 继续等 1 Enforcing '' 1
chk "pr 还在 ⇒ 谁都别喊停"              继续等 继续等 1 Enforcing 21751 0

# ---- 漂移闸 ----
D=$(grep -c 'blank_now' kmod/go.sh); L=$(grep -c 'SAWPER' kmod/go.sh)
O=$(grep -c "grep -acF '\[SEN\]'" kmod/go.sh); K=$(grep -c 'blank_gate.sh' kmod/go.sh)
if [ "$D" -ge 1 ] && [ "$L" -ge 2 ] && [ "$O" = "0" ] && [ "$K" -ge 1 ]; then
    echo "  ✓ 漂移闸：go.sh 引用 blank_now($D)/SAWPER($L)/source blank_gate($K)，旧 [SEN] 谓词残留=$O"
else
    echo "  [x] 漂移闸：blank_now=$D SAWPER=$L source=$K 旧SEN=$O ⇒ go.sh 与这份自测可能已分叉"; fails=$((fails + 1))
fi
# go.sh 语法(§6.290 那次编辑漏删 else 就是被这条抓到的)
if bash -n kmod/go.sh 2>/dev/null; then echo '  ✓ bash -n kmod/go.sh 通过'; else echo '  [x] go.sh 语法不过'; fails=$((fails + 1)); fi
[ "$fails" = 0 ] && { echo 'SELFTEST 全过(7/7)'; exit 0; } || { echo "失败 $fails 格"; exit 1; }
