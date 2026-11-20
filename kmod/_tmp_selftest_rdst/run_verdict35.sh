#!/usr/bin/env bash
# 阶梯判据块的 selftest(四条臂共用一把尺) —— 好件格 + **自动差分变异**。
#   块从腿里**现抽**：awk 取 `# --- 6b)` 到 `# --- 7)` 之间 ⇒ 改腿不用改这份。
#   ★臂的身份**全部从腿里现读**，一个都不写死在本自测里：
#     `WANT_STEPS=`(这条臂该读回几步) ＋ 块里有没有 `rd_rc`／`prs_rc` 那两支(决定多跑哪几格)。
#     并现印"抽的是哪件＋块有多少字节"——例 207：上一版我"两条臂都量"其实**根本没换臂**(循环变量 vs 环境变量)，
#     四条臂的字节数各不相同(77/78/79/80 臂)才算真换过。
#   ★变异用"差分"不用"坏件必须印某个词"：例 199(两臂同形＝没判别力)＋例 205(我把期望方向写反)。
set -u
cd "$(dirname "$0")/../.." || exit 9
LEG="${LEG:-kmod/w1035_noparam_leg.sh}"
FX=kmod/_tmp_selftest_rdst/fx35
VB=$FX/block_verdict35.sh
mkdir -p "$FX"

WS=$(grep -m1 '^WANT_STEPS=' "$LEG" | cut -d= -f2)
WS=${WS:-0}
# ★第 82 发那条臂多了两个旋钮(slack/abi)＋一个输入面证人(cp_same)：值一律**从腿里现读**，
#   自测这边不写死(写死＝有一天腿改了自测还在替它说话)。老三条臂腿里没有这些名 ⇒ 读成 0/空，
#   下面那些新格由 HAS_* 门控，老臂的格数与判定一字不变。
WL=$(grep -m1 '^WANT_SLACK=' "$LEG" | cut -d= -f2); WL=${WL:-0}
WA=$(grep -m1 '^WANT_ABI=' "$LEG" | cut -d= -f2); WA=${WA:-0}
awk '/^# --- 6b\)/{f=1} /^# --- 7\)/{f=0} f' "$LEG" > "$VB"
N=$(wc -l < "$VB"); B=$(wc -c < "$VB")
echo "腿=$LEG  WANT_STEPS=$WS  WANT_SLACK=$WL  WANT_ABI=$WA(全部现读)  抽出判据块 行数=$N 字节=$B"
[ "$B" -gt 100 ] || { echo "FAIL 判据块抽空了(锚点变了？)"; exit 7; }
grep -q 'NP_VERDICT' "$VB" || { echo "FAIL 抽出来的块里没有结论句(抽错段了)"; exit 7; }
bash -n "$VB" || { echo "FAIL 抽出来的判据块语法不过(截断了嵌套 if)"; exit 7; }
# ★探测"这条臂有没有那一支"要看**块里有没有拿它做判断**(测试式)，不能看结论文案的措辞，也不能只看变量出现：
#   ·按文案 grep ⇒ 第 82 发那条臂我改了措辞，C7/C8/C9 被**静默跳过**(跳过不报红＝例 206 那个坑)；
#   ·只看 `$RD` 出现过 ⇒ 阶梯老臂只是在 `pr_err` 文本里印 `rd_rc=$RD`，会被误判成"有这一支"⇒ C7 替一条不存在的支要结论。
# ★★写第一条测试式探测器时我自查了一次：上一版尾巴带个 `=`(` *[!=]=`)，于是**只认 `!=`、不认 `= "0"`**，
#   结果四条臂的 `prs_rc` 支全被当成"没有"⇒ C8/C9/M4/M5 从这把握尺诞生起就没跑过(而注释里我写的正是"两种都吃")。
#   ⇒ 探测器只看"这个名字后面跟了个比较运算符"，运算符本身长什么样不重要；并且**当场印命中数**，
#     数成 0 的支会被明说"不适用"，谁跳过了一眼看得见。
# ★数的是**匹配个数**不是行数(夹具那一行两条式都要算到——上一版用 grep -c 数出 1，把自证判成"探测器坏了")。
BR() { grep -oE '\[ *"\$'"$1"'" *[!=]' "$VB" | wc -l | tr -d ' '; }
# ★探测器自己也要有正对照(例 206：先证明闸会红，再拿"命中 0"当凭据)：
#   它决定哪些格子跑、哪些"不适用"，它坏了就是**整把握尺静默少跑四格还印 PASS**。
#   ⇒ 拿一个两种写法都有的夹具喂它，数必须＝2；不等于 2 直接退出，不往下装绿。
selfcheck_BR() {
    local F=$FX/br_fixture.sh SAVE=$VB T
    printf 'if [ "$FOO" = "0" ]; then :; elif [ "$FOO" != "0" ]; then :; fi\n' > "$F"
    VB="$F"; T=$(BR FOO); VB=$SAVE
    [ "$T" = 2 ] || { echo "FAIL 探测器 BR 在夹具上数到 $T(应为 2：正向式＋反向式各一) ⇒ 它分不清『这一支没有』和『我不会认』，本把握尺作废"; exit 8; }
    echo "探测器自证：夹具上 BR FOO=$T(应为 2) ⇒ 命中 0 才是真的『本臂没有那一支』"
}
selfcheck_BR
has() { [ "$(BR "$1")" -gt 0 ] && echo 1 || echo 0; }
HAS_RD=$(has RD); HAS_PRS=$(has PRS); HAS_SLK=$(has SLKR); HAS_ABI=$(has ABI)
HAS_CP=$(has COPY); HAS_CPS=$(has CPSAME)
N21=$(grep -cE '\[ *"\$ST" *= *"21" *\]' "$VB"); HAS_ST21=$([ "$N21" -gt 0 ] && echo 1 || echo 0)
echo "本臂的测试式命中数(现数)：RD=$(BR RD) PRS=$(BR PRS) SLKR=$(BR SLKR) ABI=$(BR ABI) COPY=$(BR COPY) CPSAME=$(BR CPSAME) ST=21:$N21"
echo "本臂的额外支：rd=$HAS_RD prs=$HAS_PRS slack=$HAS_SLK abi=$HAS_ABI copy=$HAS_CP cp_same=$HAS_CPS stage21=$HAS_ST21"

fail=0
ok()  { printf '  [OK] %s\n' "$1"; }
bad() { printf '  [BAD] %s\n' "$1"; fail=1; }

# concl <块> <INMOD> <RC> <STEPSR> <ST> [RD] [PRS] [SLKR] [ABI] [COPY] [CPSAME] [CP_RC]
#   ★顶层全局必须一起注进去(例 188③)：WANT_STEPS/WANT_SLACK/WANT_ABI 漏任何一个，块里那变量就是空串，红的是仪器。
#     缺省值取"这条臂的期望值"(SLKR←WANT_SLACK 等) ⇒ 老三条臂不必认识新旋钮，新那条臂要测"没拧上"只需显式给坏值。
#   ★一个文件只许一个写者(§6.461)：块自己写 INNER，stderr 另开一份。
concl() {
    local L=$FX/inner.log E=$FX/err.log
    : > "$L"; : > "$E"
    INMOD="$2" RC="$3" STEPSR="$4" ST="$5" RD="${6:-0}" PRS="${7:-0}" \
        SLKR="${8:-$WL}" ABI="${9:-$WA}" COPY="${10:-1}" CPSAME="${11:-1}" CPRC="${12:-0}" \
        CPH=5457979107816203493 \
        PLEN=1356948 PSUM=5457979107816203493 SYM=15 SLAB=0 LR=-1 NEL=12683 VER=30 MLS=1 \
        WANT_STEPS="$WS" WANT_SLACK="$WL" WANT_ABI="$WA" L="$L" bash "$1" 2>"$E"
    grep -a 'NP_VERDICT' "$L" | head -1
    [ -s "$E" ] && echo "  (stderr) $(head -2 "$E" | tr '\n' ' ')"
}

# run <块> <INMOD> <RC> <STEPSR> <ST> <RD> <PRS> <SLKR> <ABI> <COPY> <CPSAME> <期望含> <期望不许含> <标题>
#   ★bash 里 `$10` 是 `${1}0`！参数≥10 一律要写大括号。上一版这条潜伏在标题位($10)上只把标题印错，
#     这次我把期望位也推到 $12/$13，它就把"块路径＋数字 2/3/4"当期望值 ⇒ 五格假红。
run() {
    local out
    out=$(concl "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}")
    sed 's/^/        /' <<<"$out"
    if grep -qF -- "${12}" <<<"$out" && ! grep -qF -- "${13}" <<<"$out"; then
      ok "${14}"
    else
      bad "${14} (期望含[${12}]、且不含[${13}])"
    fi
}

echo "--- 好件格子(阶梯共用的六格 ＋ 第 82 发那条臂的新支；后四列 slack/abi/copy/cp_same 缺省＝"对上了") ---"
run "$VB" 1 0 "$WS" 99 0 0 "" "" "" "" "NP_VERDICT=判正"        "NP_VERDICT=未测" "C1 走到本臂出口＋上游都成功 ⇒ 判正"
run "$VB" 1 0 99    99 0 0 "" "" "" "" "NP_VERDICT=未测"        "NP_VERDICT=判正" "C2 ★臂证人：rt_steps 读回的不是本臂那个值 ⇒ 不许出结论"
run "$VB" 0 0 ""    "" 0 0 "" "" "" "" "NP_VERDICT=未测"        "NP_VERDICT=判正" "C3 rc=0 却不在册 ⇒ 未测(自相矛盾不当结论)"
run "$VB" 0 1 ""    "" 0 0 "" "" "" "" "NP_VERDICT=判负"        "NP_VERDICT=判正" "C4 被拒 ⇒ 判负(不等于解释第 72/73 发)"
run "$VB" 1 0 "$WS" -1 0 0 "" "" "" "" "NP_VERDICT=未测"        "NP_VERDICT=判正" "C5 在册却 -1 ⇒ 未测(先查仪器)"
run "$VB" 1 0 "$WS" 4  0 0 "" "" "" "" "NP_VERDICT=停在第 4 步" "NP_VERDICT=判正" "C6 停在中间步 ⇒ 报步号＋附注"
# C7 的期望随臂走：阶梯那三条臂的口径是"上游 stage2 失败＝我们那份 reader 答'判负'"，
#   第 82 发那条臂改成更诚实的**未测**(上游断了＝这一格没被问到，不许替它答题)。
#   ⇒ 期望词从块里**现读**(有"没被问到"就走未测口径)，两边都不写死。
C7_EXP=判负; C7_NO=判正
grep -q '没被问到' "$VB" && { C7_EXP=未测; C7_NO=判; }
if [ "$HAS_RD" = 1 ]; then
  run "$VB" 1 0 "$WS" 99 -13 0 "" "" "" "" "NP_VERDICT=$C7_EXP"    "NP_VERDICT=判正" "C7 stage2 返回错误 ⇒ 按本臂口径出 $C7_EXP(不是判正)"
else
  ok "C7 不适用：本臂块里没有 rd_rc 这个量"
fi
if [ "$HAS_PRS" = 1 ]; then
  run "$VB" 1 0 "$WS" 99 0 -12 "" "" "" "" "NP_VERDICT=判负"    "NP_VERDICT=判正" "C8 stage3(prs_rc) 返回错误 ⇒ 判负并抄 ver/mls/nel"
  run "$VB" 1 0 "$WS" 99 -1 0  "" "" "" "" "NP_VERDICT=未测"    "NP_VERDICT=判"   "C9 ★上游 stage2 就断 ⇒ 我们那份 reader 没被问到 ⇒ 未测(不许替它答题)"
else
  ok "C8/C9 不适用：本臂没有「prs_rc」那一支"
fi
# ---- 第 82 发那条臂独有的五支(slack/abi/没吃副本/哈希不一致/停在搬副本) ----
if [ "$HAS_SLK" = 1 ]; then
  run "$VB" 1 0 "$WS" 99 0 0 0  "$WA" 1 1 "NP_VERDICT=未测"     "NP_VERDICT=判正" "C10 旋钮没拧上(slack 读回 0 ≠ 本臂 $WL) ⇒ 未测：这一格根本没测到余量"
else
  ok "C10 不适用(本臂无 slack 支)"
fi
if [ "$HAS_ABI" = 1 ]; then
  run "$VB" 1 0 "$WS" 99 0 0 "$WL" 999 1 1 "NP_VERDICT=未测"    "NP_VERDICT=判正" "C11 ★件号不对(装上去的不是这一版件) ⇒ 整格读数不算——这是"臂到底派没派上去"那一格的第三马甲"
else
  ok "C11 不适用(本臂无 abi 支)"
fi
if [ "$HAS_CP" = 1 ]; then
  run "$VB" 1 0 "$WS" 99 0 0 "$WL" "$WA" -1 1 "NP_VERDICT=未测" "NP_VERDICT=判正" "C12 拧上了却没吃副本(copy=-1) ⇒ 量的还是原件 ⇒ 未测"
else
  ok "C12 不适用(本臂无 copy 支)"
fi
if [ "$HAS_CPS" = 1 ]; then
  run "$VB" 1 0 "$WS" 99 0 0 "$WL" "$WA" 1 0 "NP_VERDICT=未测"  "NP_VERDICT=判正" "C13 ★副本与原件哈希不同(cp_same=0) ⇒ 我换了被测对象 ⇒ 全格未测"
else
  ok "C13 不适用(本臂无 cp_same 支)"
fi
if [ "$HAS_ST21" = 1 ]; then
  run "$VB" 1 0 "$WS" 21 0 0 "$WL" "$WA" -1 -1 "NP_VERDICT=停在搬副本那步" "NP_VERDICT=判正" "C14 停在搬副本(stage=21，vmalloc 没下来) ⇒ 报 cp_rc 而不是猜"
else
  ok "C14 不适用(本臂无 stage=21 支)"
fi

echo "--- 自动变异(同一组输入，摘掉那一支之后结论**必须变**；不变＝那一支是装饰) ---"
m_steps() { grep -Ev 'STEPSR.*!=' "$1" > "$2"; }
m_inmod() { sed 's/if \[ "$INMOD" != "1" \]/if [ "x" = "y" ]/' "$1" > "$2"; }
# ★变异夹具的匹配式要**两种写法都吃**：臂里 RD/PRS 那支可能是 `[ "$RD" = "0" ]` 也可能是 `[ "$RD" != "0" ]`，
#   只写一种 ⇒ 另一条臂上"夹具没改动任何字节"(这本身是好的：它会红，不会假装跑过)。
# ★★极性：摘掉一支＝**把那个量当成"没问题"**(正向式 `= "0"` 恒真、反向式 `!= "0"` 恒假)，不是"所有式恒真"。
#   上一版两条都写成恒真，在阶梯臂上碰巧能翻面(恒真把"判正"那支抬起来先答了)，
#   在第 82 发那条臂上就**同形**了：那块里 `RD != 0`(未测)排在判正之前，恒真＝让它照常先答 ⇒ 变异等于没跑。
#   ⇒ 教训：差分断言的**方向**不写死了，**极性**也别写死——按"该量假装成功"定极性，两条式各归各。
m_rd()    { sed 's/\[ "$RD" = "0" \]/[ "1" = "1" ]/g; s/\[ "$RD" != "0" \]/[ "1" = "0" ]/g' "$1" > "$2"; }
m_prs()   { sed 's/\[ "$PRS" = "0" \]/[ "1" = "1" ]/g; s/\[ "$PRS" != "0" \]/[ "1" = "0" ]/g' "$1" > "$2"; }
m_slk()   { grep -Ev 'SLKR.*!=' "$1" > "$2"; }
m_abi()   { grep -Ev 'ABI.*!=' "$1" > "$2"; }
m_cps()   { grep -Ev 'CPSAME.*!=' "$1" > "$2"; }

mut() { # $1=制造器 $2..$11=输入(INMOD RC STEPSR ST RD PRS SLKR ABI COPY CPSAME) $12=标题
    local M=$FX/mut_$1.sh g r
    "$1" "$VB" "$M"
    if cmp -s "$M" "$VB"; then bad "${12} 夹具没改动任何字节(模式没命中) ⇒ 这条变异等于没跑"; return; fi
    # ★坏件自己得是个**能跑的仪器**：语法不过、或一行结论都不印 ⇒ 那是"仪器坏了"不是"结论翻面"(例 194：没输出不许当通过)。
    #   上一版没有这道闸，"删行型变异"一旦把块弄断，坏件读数是**空串**，跟好件那行当然"不一样"⇒ 白给我一格 OK。
    if ! bash -n "$M" 2>/dev/null; then bad "${12} 坏件语法都不过 ⇒ 这格变异作废(改夹具，别拿空读数当翻面)"; return; fi
    g=$(concl "$VB" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}")
    r=$(concl "$M"  "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}")
    echo "        好件=$g"; echo "        坏件=$r"
    if [ -z "$r" ]; then bad "${12} 坏件没印出任何结论行 ⇒ 作废(空读数≠翻面)"; return; fi
    if [ "$g" = "$r" ]; then bad "${12} 两臂同形 ⇒ 那一支没承重，对应的好件格是假绿"
    else ok "${12} 结论翻面(⇒ 那一支确实是承重的)"; fi
}
mut m_steps 1 0 99 99 0 0 "" "" "" "" "M1 摘掉「rt_steps 必须等于本臂值」那支"
mut m_inmod 0 0 ""  "" 0 0 "" "" "" "" "M2 把「在册与否」那支永假化"
if [ "$HAS_RD" = 1 ]; then
  mut m_rd 1 0 "$WS" 99 -13 0 "" "" "" "" "M3 摘掉「stage2 必须成功」那支"
else
  ok "M3 不适用(本臂无 RD 支)"
fi
if [ "$HAS_PRS" = 1 ]; then
  mut m_prs 1 0 "$WS" 99 0 -12 "" "" "" "" "M4 摘掉「stage3 必须成功」那支"
  mut m_rd  1 0 "$WS" 99 -1 0  "" "" "" "" "M5 摘掉「上游 stage2 必须成功」那支(⇒ C9 那格会不会被误判成判负)"
else
  ok "M4/M5 不适用(本臂无 PRS 支)"
fi
if [ "$HAS_SLK" = 1 ]; then
  mut m_slk 1 0 "$WS" 99 0 0 0 "$WA" 1 1 "M6 摘掉「slack 必须等于本臂值」那支(C10 必须翻面)"
else
  ok "M6 不适用(本臂无 slack 支)"
fi
if [ "$HAS_ABI" = 1 ]; then
  mut m_abi 1 0 "$WS" 99 0 0 "$WL" 999 1 1 "M7 摘掉「件号必须等于本臂值」那支(C11 必须翻面)"
else
  ok "M7 不适用(本臂无 abi 支)"
fi
if [ "$HAS_CPS" = 1 ]; then
  mut m_cps 1 0 "$WS" 99 0 0 "$WL" "$WA" 1 0 "M8 摘掉「副本哈希必须一致」那支(C13 必须翻面：不摘就会把"换了被测对象"当结论)"
else
  ok "M8 不适用(本臂无 cp_same 支)"
fi

echo "=== 结论：selftest $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ==="
rm -rf "$FX"
exit "$fail"
