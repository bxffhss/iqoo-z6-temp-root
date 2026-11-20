#!/usr/bin/env bash
# #219 新开关 LEG1ONLY 的 selftest：把 go.sh 里"派完 LEG1 就跳第 4~7 步"那两段**逐字抽出来**跑两格。
#   双向判据(例 88/100/116/192)：
#     格1 不给 LEG1ONLY ⇒ 第 4~7 步必须照旧跑(交付链一字不变)；
#     格2 给 LEG1ONLY=1 ⇒ 那几步一条都不许跑，且必须**明说"跳过/未测"**(缺席不许静默)。
#   ★抽取本身要有牙：先断言抽出的两段非空且含 SKIP4，否则"锚点错了 ⇒ 测试永远绿"就是例 192 第二种没牙。
set -u
cd "$(dirname "$0")/../.." || exit 9
G=kmod/go.sh
BLK=kmod/_tmp_selftest_rdst/block_leg1only.sh
TAIL=kmod/_tmp_selftest_rdst/tail_leg1only.sh

sed -n '/^# === 3.9)/,/^if \[ "${SKIP4:-0}" != 1 \]; then$/p' "$G" > "$BLK"
sed -n '/^fi   # ← if \[ "${SKIP4:-0}" != 1 \]/p' "$G" > "$TAIL"

echo "抽出的守卫块：行数=$(wc -l < "$BLK") 字节=$(wc -c < "$BLK")  收尾行：行数=$(wc -l < "$TAIL")"
[ "$(wc -c < "$BLK")" -gt 40 ] || { echo "FAIL 守卫块抽空了(锚点错了或改动没落进 go.sh)"; exit 7; }
[ "$(wc -l < "$TAIL")" -eq 1 ] || { echo "FAIL 收尾 fi 行没抽到(期望恰好 1 行，实得 $(wc -l < "$TAIL"))"; exit 7; }
grep -q 'SKIP4' "$BLK" || { echo "FAIL 守卫块里没有 SKIP4(抽错段了)"; exit 7; }
grep -q 'LEG1ONLY' "$BLK" || { echo "FAIL 守卫块里没有 LEG1ONLY(开关名没落进去)"; exit 7; }

F=kmod/_tmp_selftest_rdst/synth_leg1only.sh
{ cat "$BLK"; echo 'echo STEP4_RAN'; echo 'echo STEP5_RAN'; echo 'echo STEP6_RAN'; echo 'echo STEP7_RAN'; cat "$TAIL"; echo 'echo STEP8_RAN'; } > "$F"
bash -n "$F" || { echo "FAIL 拼出来的合成脚本语法不过(两段守卫没配对)"; exit 7; }

fail=0
run() { # $1=LEG1ONLY 值(空=不给) $2=期望词 $3=忌词 $4=标题
    local out
    if [ -z "$1" ]; then
        out=$(env -u LEG1ONLY bash "$F" 2>&1)
    else
        out=$(LEG1ONLY="$1" bash "$F" 2>&1)
    fi
    local p n
    if grep -qF -- "$2" <<<"$out"; then p=OK; else p=MISS; fi
    if [ -z "$3" ]; then n=OK; elif grep -qF -- "$3" <<<"$out"; then n=BAD; else n=OK; fi
    { [ "$p" = OK ] && [ "$n" = OK ]; } || fail=1
    echo "  [$p/$n] $4  LEG1ONLY=[${1:-<未给>}]"
    # ★w413 数的是 [OK] 行数(总闸那条 item 的期望=2)；没有这个词这条 selftest 在总闸里就是"0 格也绿"
    { [ "$p" = OK ] && [ "$n" = OK ]; } && echo "      [OK] $4"
    sed 's/^/              /' <<<"$out"
}
echo "=== 格1 不给 LEG1ONLY ⇒ 第 4~7 步照旧跑，且不许出现"跳过"文案 ==="
run '' 'STEP4_RAN' '跳过第 4~7 步' "交付形状不变"
echo "=== 格2 给 LEG1ONLY=1 ⇒ 第 4~7 步一条不跑，但必须明写跳过(缺席＝未测，不许静默) ==="
run '1' '跳过第 4~7 步' 'STEP4_RAN' "开关生效"

echo "=== 语法检查(真 go.sh) ==="
if bash -n "$G"; then echo "  bash -n rc=0"; else echo "  bash -n FAIL"; fail=1; fi
echo "=== 结论：selftest $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ==="
exit "$fail"
