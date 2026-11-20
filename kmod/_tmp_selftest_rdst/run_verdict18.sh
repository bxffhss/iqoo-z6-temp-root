#!/usr/bin/env bash
# w1018 判据块的 selftest —— 两组九格，全部**从腿里现抽**(改腿不用改这份)：
#   A 组(1–4)＝`rd()` 那个读数形状：第 70 发就是被"read 在 EOF-无换行时返回 1、但值已经赋进去了"废掉的
#              ⇒ 判据必须"判空不判 rc"，并且**失败时 errno 文本要落在证件里**(v1 用 2>/dev/null 把证人丢了)。
#   B 组(5–9)＝判据块五格：域落地/域丢/读不出/域走形/**执法前后不一致**——最后这格是牙，
#              它红着说明"中途有人换域"时本判据不许给出判正/判负(例 192：只测会放行的不算判据)。
# ★变异测试：LEG=<坏件> 指到我复制出来的两份坏件上，A1 与 B9 必须转红(见本文件末尾的两行注释)。
set -u
cd "$(dirname "$0")/../.." || exit 9
LEG="${LEG:-kmod/w1018_mlsrange_leg.sh}"
RD=kmod/_tmp_selftest_rdst/block_rd18.sh
SR=kmod/_tmp_selftest_rdst/synth_rd18.sh
VB=kmod/_tmp_selftest_rdst/block_verdict18.sh
SV=kmod/_tmp_selftest_rdst/synth_verdict18.sh
FX=kmod/_tmp_selftest_rdst/fx18
WANT=$(grep -m1 '^WANT_DOM=' "$LEG" | cut -d= -f2)
BASE=$(grep -m1 '^BASE_DOM=' "$LEG" | cut -d= -f2)
echo "腿=$LEG  从腿里现读 WANT_DOM=$WANT  BASE_DOM=$BASE"
[ -n "$WANT" ] && [ -n "$BASE" ] || { echo "FAIL 读不到 WANT_DOM/BASE_DOM 锚点(腿改名了？)"; exit 7; }

mkdir -p "$FX"
printf 'u:r:shell:s0'        > "$FX/nonl"     # /proc/self/attr/current 的真实形状：无换行结尾
printf 'u:r:shell:s0\n'      > "$FX/withnl"
: > "$FX/empty"

awk '/^rd\(\)/{f=1} f{print} f&&/^}$/{exit}' "$LEG" > "$RD"
echo "抽出 rd 块：行数=$(wc -l < "$RD") 字节=$(wc -c < "$RD")"
[ "$(wc -c < "$RD")" -gt 50 ] || { echo "FAIL rd 块抽空了(锚点错了)"; exit 7; }
grep -q 'RVAL' "$RD" || { echo "FAIL 抽出来的块里没有 RVAL(抽错件了)"; exit 7; }
{ cat "$RD"; echo 'exec 9>"$2"'; echo 'rd "$1"'; echo 'echo "GOT=[$RVAL] rc=$RCODE"'; } > "$SR"
bash -n "$SR" || { echo "FAIL 拼出来的 rd 件语法不过"; exit 7; }

awk '/^# --- 6\) 判据/{f=1} /^# --- 7\)/{f=0} f' "$LEG" > "$VB"
echo "抽出判据块：行数=$(wc -l < "$VB") 字节=$(wc -c < "$VB")"
[ "$(wc -c < "$VB")" -gt 100 ] || { echo "FAIL 判据块抽空了(锚点错了)"; exit 7; }
grep -q 'MLS_RANGE_VERDICT' "$VB" || { echo "FAIL 块里没有结论句(抽错段了)"; exit 7; }
{ echo 'say() { echo "$1"; }'; cat "$VB"; } > "$SV"
bash -n "$SV" || { echo "FAIL 拼出来的判据语法不过(抽取截断了嵌套 if)"; exit 7; }

fail=0
ok()  { printf '  [OK] %s\n' "$1"; }
bad() { printf '  [BAD] %s\n' "$1"; fail=1; }

# ===== A 组：读数形状 =====
CAP="$FX/cap.log"
# A1 ★第 70 发的回归格：无换行 ⇒ read 返 1，但值必须在变量里(判空不判 rc)
: > "$CAP"
out=$(bash "$SR" "$FX/nonl" "$CAP" 2>&1); sed 's/^/        /' <<<"$out"
grep -qF 'GOT=[u:r:shell:s0]' <<<"$out" && grep -qE 'rc=1$' <<<"$out" \
  && ok "A1 无换行读数：值保住(GOT=[u:r:shell:s0]) 且 rc=1 只当附注" \
  || bad "A1 无换行读数被覆盖成空 ⇒ 第 70 发那个『(读不出)』又回来了：$out"
# A2 有换行 ⇒ 值在、rc=0
out=$(bash "$SR" "$FX/withnl" "$CAP" 2>&1); sed 's/^/        /' <<<"$out"
grep -qE 'GOT=\[u:r:shell:s0\] rc=0$' <<<"$out" \
  && ok "A2 有换行读数：值保住且 rc=0" || bad "A2 有换行那格也没读到：$out"
# A3 文件不在 ⇒ 值必须为空，且 **errno 文本要落进证件**(否则又只能猜)
: > "$CAP"
out=$(bash "$SR" "$FX/no_such_file" "$CAP" 2>&1); sed 's/^/        /' <<<"$out"
grep -qE 'GOT=\[\] rc=[1-9]' <<<"$out" && grep -qiE 'open|No such|cannot' "$CAP" \
  && ok "A3 文件不在：GOT 为空＋errno 文本已收进证件($(tr -d '\n' < "$CAP" | cut -c1-60))" \
  || bad "A3 失败读数没有 errno 证人(证件里只有 $(wc -c < "$CAP") 字节)：$out"
# A4 空文件 ⇒ 判空必须说"读不出"(不许把空内容当成有效读数)
out=$(bash "$SR" "$FX/empty" "$CAP" 2>&1); sed 's/^/        /' <<<"$out"
grep -qE 'GOT=\[\] rc=[0-9]' <<<"$out" && ok "A4 空文件：GOT=[] ⇒ 判据会走『未测』分支" || bad "A4 空文件读数形状不对：$out"

# ===== B 组：判据五格 =====
run() { # $1=DOM_NOW $2=DOM_AFTER $3=IDZ $4=期望子串 $5=不许出现的子串 $6=标题
    local out
    out=$(DOM_NOW="$1" DOM_AFTER="$2" IDZ="$3" S0_RCODE=0 WANT_DOM="$WANT" BASE_DOM="$BASE" bash "$SV" 2>&1)
    sed 's/^/        /' <<<"$out"
    if grep -qF -- "$4" <<<"$out" && ! grep -qF -- "$5" <<<"$out"; then
      ok "$6"
    else
      bad "$6  (期望含[$4]、且不含[$5])"
    fi
}
echo "--- B5 域落地(两把读数一致)⇒ 判正，且不许说未测 ---"
run "$WANT" "$WANT" "$WANT" "MLS_RANGE_VERDICT=判正" "MLS_RANGE_VERDICT=未测" "B5 落地⇒判正"
echo "--- B6 域＝交付基线(范围被丢)⇒ 判负 ---"
run "$BASE" "$BASE" "$BASE" "MLS_RANGE_VERDICT=判负" "MLS_RANGE_VERDICT=判正" "B6 范围丢掉⇒判负"
echo "--- B7 读不出(空)⇒ 未测 ---"
run "" "" "" "MLS_RANGE_VERDICT=未测(在线域读不出" "MLS_RANGE_VERDICT=判" "B7 空读数⇒未测"
echo "--- B8 域走形(u:r:init:s0)⇒ 未测 ---"
run "u:r:init:s0" "u:r:init:s0" "u:r:init:s0" "MLS_RANGE_VERDICT=未测(在线域=" "MLS_RANGE_VERDICT=判" "B8 走形⇒未测"
echo "--- B9 执法前后两个读数不一致 ⇒ 必须未测(★牙：这一格红着就是中途换域) ---"
run "$WANT" "$BASE" "$WANT" "MLS_RANGE_VERDICT=未测(执法前=" "MLS_RANGE_VERDICT=判正" "B9 前后不一致⇒未测"

echo "=== 结论：selftest $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ==="
echo "★变异测试(手动，两次都要转红)："
echo "  1) 复制腿并把 rd 里那行读改成 '{ read -r RVAL < \"\$1\"; } 2>&9 || RVAL=\"\"'(＝第 70 发的 rc 兜底) ⇒ LEG=复制件 跑，A1 必须 [BAD]"
echo "  2) 复制腿并删掉判据块里『执法前/后不一致』那条 elif ⇒ LEG=复制件 跑，B9 必须 [BAD]"
exit "$fail"
