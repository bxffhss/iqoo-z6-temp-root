#!/usr/bin/env bash
# run_pkgcheck.sh —— 给 w413_selftest_sweep.sh 的 **3b(设备侧 suw 包指纹读回)** 做五格离线自测(不碰设备)。
#   五格：①注入"台账现行那包"的 md5 ⇒ 必须**判绿**且两条断言真的数到(例 88：第一遍得真的改)；
#         ②注入"回退位那包"的 md5 ⇒ 必须判红，并且打出"别开窗＋重装指引"那句；
#         ③注入空读数 ⇒ 必须判红("读不到"不许当"没问题"，例 80)；
#         ④台账指到空文件 ⇒ 必须判红(定值没有生产者，例 116)；
#         ⑤桩掉 adb 让它不在线 ⇒ 必须显式"没跑"，且**一条断言都不许数**。
#   ★切片的边界也要有牙：起点必须含注入旋钮，终点不许把"汇总"那半(它自己 exit)吞进来。
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
W=$(mktemp -d)
awk '/=== 3b\)/{f=1} /=== 汇总/{f=0} f' kmod/w413_selftest_sweep.sh > "$W/block.sh"
[ -s "$W/block.sh" ] || { echo "[x] 没能切出 3b 那段 ⇒ 锚点失效，别继续测"; exit 1; }
grep -q 'W413_FAKE_MD5' "$W/block.sh" || { echo "[x] 切片里没有注入旋钮 ⇒ 起点锚错了"; exit 1; }
grep -q '离线自检闸 全绿' "$W/block.sh" && { echo "[x] 切片把汇总那半也吞进来了(那段会自己 exit)"; exit 1; }
echo "切片行数=$(wc -l < "$W/block.sh")"

CUR=$(grep -aoE 'suw_manager_singletop_20261018\.apk`＝`[0-9a-f]{8}' kmod/DELIVERY.md | grep -oE '[0-9a-f]{8}$' | tail -1)
OLD=$(grep -aoE 'suw_reinstall\.apk`＝`[0-9a-f]{8}' kmod/DELIVERY.md | grep -oE '[0-9a-f]{8}$' | tail -1)
[ -n "$CUR" ] && [ -n "$OLD" ] || { echo "[x] 台账里两个前缀没登记齐(现行=$CUR 回退=$OLD) ⇒ 先登记再测"; exit 1; }
echo "台账前缀：现行=$CUR｜回退=$OLD"
# ★夹具用**本机冻结包实测的 32 位 md5**(不是台账里那个缩写前缀)：
#   第 1 版夹具就是喂了 8 位前缀 ⇒ 被判"非空 32 位"那条腿拦下，这正好证明那条腿有牙，但也证明
#   夹具必须与真机同源(真机上 md5sum 一定给 32 位)。台账前缀与本机实测前缀另设一条一致性断言。
CUR32=$(md5sum kmod/suw_manager_singletop_20261018.apk | cut -c1-32)
OLD32=$(md5sum kmod/suw_reinstall.apk | cut -c1-32)
echo "本机冻结包实测：现行=$CUR32｜回退=$OLD32"

nchk=0; fail=0
run_case() { # $1=tag $2=FAKE(1=注入) $3=注入的 md5(可为空) $4=台账路径
    : > "$W/out_$1.txt"
    (
        cd "$W" || exit 1
        adb() { echo "ADB[$*]"; return 1; }
        fail=0
        W413_FAKE="$2" W413_FAKE_MD5="$3" W413_DOC="$4"
        export W413_FAKE W413_FAKE_MD5 W413_DOC
        source "$W/block.sh" >> "$W/out_$1.txt" 2>&1
    )
    echo "----- case $1 (FAKE='$2' md5='${3:-}' doc=$(basename "$4")) -----"
    sed 's/^/    /' "$W/out_$1.txt"
}
chk() { # 条数由这里自己加(例 127：不许手数)
    nchk=$((nchk+1))
    if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi
}
nb() { grep -c '\[BAD\]' "$W/out_$1.txt"; }
no_() { grep -c '\[OK\]' "$W/out_$1.txt"; }

run_case c1 1 "$CUR32"    "$ROOT/kmod/DELIVERY.md"
run_case c2 1 "$OLD32"    "$ROOT/kmod/DELIVERY.md"
run_case c3 1 ""          "$ROOT/kmod/DELIVERY.md"
run_case c4 1 0123456789abcdef0123456789abcdef /dev/null
run_case c5 0 ""          "$ROOT/kmod/DELIVERY.md"

B1=$(nb c1); O1=$(no_ c1)
chk "①现行那包：零 BAD 且两条断言都数到了(BAD=$B1 OK=$O1)" "$([ "$B1" = 0 ] && [ "$O1" -ge 2 ] && echo 1 || echo 0)"
B2=$(nb c2)
chk "②回退那包：判红(BAD=$B2)" "$([ "$B2" -ge 1 ] && echo 1 || echo 0)"
chk "②回退那包：给了'别开窗＋重装指引'那句" "$(grep -aq '别开窗' "$W/out_c2.txt" && echo 1 || echo 0)"
chk "③空读数：判在'非空 32 位'那条上而不是静悄悄跳过" "$(grep -aq '\[BAD\] 设备侧 md5 读得出非空 32 位' "$W/out_c3.txt" && echo 1 || echo 0)"
chk "④台账没登记：判在'定值没有生产者'那条上" "$(grep -aq '\[BAD\] 台账里登记了现行 suw 包' "$W/out_c4.txt" && echo 1 || echo 0)"
N5=$(grep -oE '3b 断言自数＝[0-9]+' "$W/out_c5.txt" | grep -oE '[0-9]+' | tail -1)
chk "⑤adb 不在线：显式'没跑'且一条断言都没数(自数=${N5:-无})" "$(grep -aq '3b 按『没测到』算' "$W/out_c5.txt" && [ "${N5:-x}" = 0 ] && echo 1 || echo 0)"
chk "⑤adb 不在线：这一格不算红(没测到≠通过，也不等于失败)" "$([ "$(nb c5)" = 0 ] && echo 1 || echo 0)"

chk "台账前缀＝本机冻结包实测前缀(定值与实物同源)" "$([ "${CUR32:0:8}" = "$CUR" ] && [ "${OLD32:0:8}" = "$OLD" ] && echo 1 || echo 0)"

echo
if [ "$fail" = 0 ]; then echo "=== run_pkgcheck 自测 PASS(共 $nchk 项断言，条数由 chk 自数) ==="; else echo "=== FAIL($nchk 项) ==="; fi
echo "临时件留在 $W(里面有 5 份 out_)"
[ "$fail" = 0 ]
