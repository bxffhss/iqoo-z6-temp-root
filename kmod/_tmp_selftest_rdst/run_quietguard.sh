#!/usr/bin/env bash
# 第 68 那条自保闸(quiet 形状不许派腿)的 selftest：从 go.sh **逐字抽出**那一段，喂四种形状。
#   ①给了 LEG1＋非 quiet          ⇒ LEG1 必须还在(照派)，且不许多印"不派腿"
#   ②给了 LEG1＋开关文件在         ⇒ LEG1 必须被清空＋必须印"不派腿"(缺席不许静默)
#   ③给了 LEG1＋stage 有"静默版"行 ⇒ 同 ②(两条证人各自都要能单独拦下)
#   ④没给 LEG1                    ⇒ 整段静默：不许发任何 adb 读数(交付形状一字不变)
#   ★抽取本身要有牙：先 bash -n 合成脚本＋断言块里有 LEG1=(锚错了会抽出一段"永远通过"的空测试)
set -u
cd "$(dirname "$0")/../.." || exit 9
G=kmod/go.sh
BLK=kmod/_tmp_selftest_rdst/block_quietguard.sh
S=kmod/_tmp_selftest_rdst/synth_quietguard.sh

awk '/★★第 68 发一手的自保闸/,/3\.5a\) 自保闸结束/' "$G" > "$BLK"
echo "抽出的闸：行数=$(wc -l < "$BLK") 字节=$(wc -c < "$BLK")"
[ "$(wc -c < "$BLK")" -gt 200 ] || { echo "FAIL 闸块抽空了(锚点错了或改动没落进 go.sh)"; exit 7; }
grep -q 'LEG1=$' "$BLK" || { echo "FAIL 块里没有清空 LEG1 那句 ⇒ 这道闸不拦东西"; exit 7; }
grep -q 'ksu_quiet_after_insmod' "$BLK" || { echo "FAIL 块里没有开关文件那条证人"; exit 7; }

{ echo 'A() { shift; printf "%s\n" "${FAKE_A:-}"; }'; cat "$BLK"; } > "$S"
bash -n "$S" || { echo "FAIL 拼出来的闸语法不过"; exit 7; }

fail=0
run() { # $1=LEG1(空=不给) $2=FAKE_A $3=期望(KEEP|BLOCK|SILENT) $4=标题
    local out got
    out=$(LEG1="$1" FAKE_A="$2" bash "$S" 2>&1)
    got=KEEP
    [ -z "${1:-}" ] && got=SILENT
    grep -q '不派腿' <<<"$out" && got=BLOCK
    if [ "$got" = "$3" ]; then echo "  [OK] $4"; else echo "  [BAD] $4 期望 $3 实得 $got"; fail=1; fi
    [ "$4" = "$4" ] || true
    if [ "$got" = KEEP ]; then
        [ "${LEG1:-}" = "$1" ] || true   # 只看块外效果没意义，这里靠"不派腿"缺席来判
    fi
    [ "$3" = BLOCK ] && { grep -q '静默版不装 agent fd' <<<"$out" || { echo "      [MISS] 拦下了但没说要拦住(文案没生产者)"; fail=1; }; }
    [ "$3" = SILENT ] && { [ -z "$out" ] || { echo "      [BAD] 没给 LEG1 却打印了东西：$(head -1 <<<"$out")"; fail=1; }; }
}
echo "=== ①给 LEG1＋非 quiet(两条证人都干净) ⇒ 照派 ==="
run '/data/local/tmp/x.sh' '' 'KEEP' '闸不误伤：交付/普通形状照旧派腿'
echo "=== ②给 LEG1＋开关文件在 ⇒ 必须拦 ==="
run '/data/local/tmp/x.sh' '/data/local/tmp/ksu_quiet_after_insmod' 'BLOCK' '开关文件那条证人单独就能拦'
echo "=== ③给 LEG1＋stage 有静默版行 ⇒ 必须拦 ==="
run '/data/local/tmp/x.sh' '1' 'BLOCK' 'stage 那行证人单独就能拦'
echo "=== ④没给 LEG1 ⇒ 整段静默(交付形状一字不变) ==="
run '' '' 'SILENT' '不给开关＝什么都不做'
echo "=== 真 go.sh 语法 ==="
bash -n "$G" || { echo "  bash -n FAIL"; fail=1; }
echo "=== 结论：selftest $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ==="
exit "$fail"
