#!/usr/bin/env bash
# run_sepd_readout.sh —— w1153 那条链的**判读段**(judge())的离线自测(0 枪，不碰设备，也不跑链)。
#   ★为什么要有它：第 97 发那一格红在"期望表"而不是被测，而链里原来只有一句
#     `fail>0 ⇒ 判负`——它把"模型红"和"跨架构不一致"压成同一个词。⇒ 判读段现在是两支：
#       ⑥a 决定性的三把(why/n/bad_at)差 ⇒ 判负(是发现)；⑥b 只差派生的两把(max_arg/lenmatch) ⇒ 模型红，
#     交给 w1154 三方对表裁决。新写的这段**自己也必须验**，否则"分岔"只是把我的一句判断写成代码。
#   ★抽取方式＝从链里**现抽** judge() 的函数体(不是我另抄一份)；抽不出来或抽太少就红 ⇒ 改了链会逼着改这里。
#     自测只 eval 这段文本，绝不执行链(链会跑总闸 ⇒ 闸里跑闸＝递归)。
#   十格：
#     R1 抽码闸：行数/字节数过线，且两支分岔与 REJ 那条都在
#     R2 正对照：读数＝表 ⇒ 判正(REJ=0 与 REJ=1 两条路都得绿)
#     R3 读数差(why 挪一格) ⇒ 必须判负(读法⑥a)，且不得出现"模型红"
#     R4 模型差(max_arg+lenmatch 挪一格) ⇒ 必须模型红(读法⑥b)，且**不得**判负
#     R5 ★want() 陷阱：读数与表全等，但同行尾 `want(why=99 n=98 …)` 故意不同 ⇒ 仍须判正
#        (取数若没把 want 摘掉，这里就会拿腿自己 echo 的旧期望当真读数＝例 222/231③ 那一族)
#     R6 字节不忠实(in_md5 换掉) ⇒ 未测(读法⑦)，不许说"内核解错了"
#     R7 控制格红(CASEOK RMMOD 0) ⇒ 判据不齐(两把控制格)
#     R8 没有 END(READY=0) ⇒ 未测(读法①)
#     R9 ★旧账不当裁判：腿自计 pass=13 fail=1，而现行表逐格全等 ⇒ REJ=1 仍判正(＝第 97 发的形状)
#     R10 真归档×真表：kmod/w103_evidence/w1153_leg_shot97.out 重判 ⇒ 判正(这一发的定性从此可重跑)
set -u
cd "$(dirname "$0")/../.." || exit 9
CHAIN=kmod/w1153_sepd_chain.sh
TBL=kmod/w1152_fixtures/expect.txt
FN=kmod/_tmp_selftest_rdst/block_sepd_judge.sh
ARC=kmod/w103_evidence/w1153_leg_shot97.out
FAIL=0; NC=0
ok() { echo "[OK] $*"; NC=$((NC+1)); }
no() { echo "[!!] $*"; FAIL=1; }

[ -f "$CHAIN" ] || { no "链不在：$CHAIN"; exit 1; }
[ -f "$TBL" ]   || { no "期望表不在：$TBL(先跑 python kmod/w1152_sepd_fixtures.py)"; exit 1; }

# ===== R1 抽码闸 =====
awk '/^judge\(\) \{$/{f=1} f{print} f&&/^\}$/{f=0}' "$CHAIN" > "$FN"
JL=$(wc -l <"$FN" | tr -dc '0-9'); JB=$(wc -c <"$FN" | tr -dc '0-9')
[ "$JL" -ge 30 ] || no "R1 抽出的 judge() 只有 $JL 行 ⇒ 锚点错了，后面全是跑空气"
[ "$JB" -gt 1500 ] || no "R1 抽出的 judge() 只有 $JB 字节 ⇒ 同上"
grep -q 'DEC=0; DRV=0; MATCH=0' "$FN" || no "R1 ⑥a/⑥b 那支分岔不在了(读法被删？)"
grep -q '读法⑥a' "$FN" && grep -q '读法⑥b' "$FN" || no "R1 两支判词缺一支 ⇒ 又压成一个词了"
grep -q 'REJ:-0' "$FN" || no "R1 REJUDGE 那条支路不在函数里(重判会走开枪那条满分口径)"
grep -q 'cl%% want(\*}' "$FN" || no "R1 没摘 want() 尾 ⇒ R5 那把牙就是摆设"
[ "$FAIL" = 0 ] && ok "R1 抽码闸：judge() 抽出 $JL 行/$JB 字节，两支分岔与 REJ 都在"

ROWS=$(grep -vc '^#' "$TBL" | tr -dc '0-9')
FULLPASS=$((ROWS + 2))
tfv() { local t="${1#*;$2=}"; if [ "$t" = "$1" ]; then TV=""; else TV="${t%%;*}"; fi; }   # 纯 bash，不 fork

# mkleg <输出文件> <形状>：形状＝ok|dec|drv|wanttrap|md5bad|normod|oldcount|noend
# ★表里每行造一条 CASE，**读数默认＝该行的期望**(这才是正对照，不是抄上一发的读数)；
#   变异形状还要把腿自己的 `CASEOK <格> 0` 与 `COUNTS fail=1` 一起改 ⇒ 夹具必须**内部自洽**，
#   否则就是在喂一个"读数与自计账互相矛盾"的假腿(真链里腿是同一份码算的，不可能只错一边)。
mkleg() {
  local out="$1" mode="$2" nm row why n at ma lm fnv md5 by frow bad=0 ok
  : >"$out"
  printf 'BEGIN v1152 up=100 boot_id=deadbeef-0000\nIDENTITY=ok\n' >>"$out"
  while read -r row; do
    case "$row" in ''|\#*) continue ;; esac
    nm=${row%% *}
    frow=";${row// /;}"
    tfv "$frow" bytes; by="$TV"; tfv "$frow" md5; md5="$TV"; tfv "$frow" fnv; fnv="$TV"
    tfv "$frow" why; why="$TV"; tfv "$frow" n; n="$TV"; tfv "$frow" bad_at; at="$TV"
    tfv "$frow" max_arg; ma="$TV"; tfv "$frow" lenmatch; lm="$TV"
    ok=1
    case "$mode" in
      dec)      [ "$nm" = ok3 ] && { why=99; ok=0; bad=1; } ;;
      drv)      [ "$nm" = ok3 ] && { ma=$((ma + 1)); lm=0; ok=0; bad=1; } ;;
      md5bad)   [ "$nm" = ok9 ] && { md5=deadbeefdeadbeefdeadbeefdeadbeef; ok=0; bad=1; } ;;
    esac
    local wt="why=$why n=$n at=$at ma=$ma lm=$lm"
    [ "$mode" = wanttrap ] && [ "$nm" = ok600 ] && wt="why=99 n=98 at=7 ma=1 lm=0"
    printf 'CASE %s ddrc=0 in_bytes=%s in_md5=%s in_fnv=%s why=%s n=%s bad_at=%s max_arg=%s lenmatch=%s rec_stmts=0 rec_trunc=0 rec_bytes=9 want(%s md5=%s fnv=%s)\n' \
      "$nm" "$by" "$md5" "$fnv" "$why" "$n" "$at" "$ma" "$lm" "$wt" "$md5" "$fnv" >>"$out"
    printf 'CASEOK %s %s\n' "$nm" "$ok" >>"$out"
  done < <(grep -v '^#' "$TBL")
  case "$mode" in
    oldcount) printf 'COUNTS pass=13 fail=1 enf=0 uname=5.4.281\n' >>"$out" ;;
    *)        printf 'COUNTS pass=%s fail=%s enf=0 uname=5.4.281\n' "$((FULLPASS - bad))" "$bad" >>"$out" ;;
  esac
  printf 'CASEOK EMPTY_CTRL 1\n' >>"$out"
  if [ "$mode" = normod ]; then printf 'CASEOK RMMOD 0\nRMMOD rc=1 modcnt=1\n' >>"$out"
  else printf 'CASEOK RMMOD 1\nRMMOD rc=0 modcnt=0\n' >>"$out"; fi
  [ "$mode" = noend ] || printf 'END up=140\n' >>"$out"
}
# ★judge() 只在进本文件时 eval **一次**(装进当前 shell)，之后每次调用只改全局 ⇒ 不在每格里 fork+eval
eval "$(cat "$FN")"
setj() { LEGARC="$1"; REJ="${2:-0}"; READY="${3:-1}"; TBLREPO="$TBL"; SHOT=T; ROWS="$ROWS"; FULLPASS="$FULLPASS"; }
# readout <腿件> <REJ> <READY> ⇒ 只回 ★那行判决(纯 bash 摘尾，不 fork)
readout() {
  local out; setj "$1" "${2:-0}" "${3:-1}"
  out=$(judge 2>&1)
  local v=${out#*_SEPD=}
  printf '%s' "${v%% ｜*}"
}
fullout() { setj "$1" "${2:-0}" "${3:-1}"; judge 2>&1; }


W=kmod/_tmp_selftest_rdst/leg_t.out
# ===== R2 正对照(两条路都要绿) =====
mkleg "$W" ok
v0=$(readout "$W" 0 1); v1=$(readout "$W" 1 1)
case "$v0" in 判正*) ok "R2 正对照(REJ=0，腿自计满分) ⇒ $v0" ;; *) no "R2 正对照 REJ=0 没判正(=$v0) ⇒ 尺写坏了" ;; esac
case "$v1" in 判正*) ok "R2 正对照(REJ=1，逐格重算 $ROWS/$ROWS) ⇒ $v1" ;; *) no "R2 正对照 REJ=1 没判正(=$v1)" ;; esac

# ===== R3 读数差 ⇒ 判负(⑥a)，不许混进模型红 =====
# ★★匹配一律带**完整词元**(`判负(读法⑥a`)，不许拿"行里出现了『判负』两个字"当证据：
#   上一版的⑥b判句里写着"不写判负"这两个否定字，被这种松匹配读成正向命中(＝第一条 R4 假红)，
#   与例 231②"计数判据要摘掉设计上必出现的那行"是同一族：判据的词元必须互斥。
mkleg "$W" dec
v=$(readout "$W" 0 1)
case "$v" in *"判负(读法⑥a"*) ok "R3 why 挪一格 ⇒ 判负(⑥a)：$v" ;; *) no "R3 读数差没判负(=$v) ⇒ 那把尺恒绿" ;; esac
case "$v" in *"模型红"*) no "R3 读数差被说成模型红 ⇒ 两支又混了"; ;; esac
f=$(fullout "$W" 0 1); grep -q '⑥a(读数差)： ok3\[why(内99≠表0)\]' <<<"$f" || no "R3 分岔明细行没点名 ok3 的 why(取数或键名变了)"

# ===== R4 只差派生两把 ⇒ 模型红，**不得**判负 =====
mkleg "$W" drv
v=$(readout "$W" 0 1)
case "$v" in *"模型红(读法⑥b"*) ok "R4 max_arg/lenmatch 挪一格 ⇒ $v" ;; *) no "R4 派生格差没走⑥b(=$v)";; esac
case "$v" in *"判负(读法⑥a"*) no "R4 模型红被判负 ⇒ 正是这一发要修的那处混淆，又回来了";; esac
f=$(fullout "$W" 0 1); grep -q '只差派生两把的格=1' <<<"$f" || no "R4 派生差计数不是 1(=$f)"

# ===== R5 want() 陷阱(专门打"取数命中行尾旧期望"这一族) =====
mkleg "$W" wanttrap
v=$(readout "$W" 1 1)
case "$v" in 判正*) ok "R5 读数全等而 want(why=99 n=98) 不同 ⇒ 仍判正(取数没被行尾旧期望劫持)：$v" ;; *) no "R5 被 want() 劫持了(=$v) ⇒ 必须摘尾再取键" ;; esac

# ===== R6 字节不忠实 ⇒ 未测(⑦) =====
mkleg "$W" md5bad
v=$(readout "$W" 1 1)
case "$v" in *"未测(读法⑦"*) ok "R6 in_md5 与表不符 ⇒ $v(不许算被测红)" ;; *) no "R6 字节红没记未测(=$v)" ;; esac
case "$v" in *"判负(读法⑥a"*|判正*) no "R6 字节不忠实却给了定性 ⇒ 读法⑦被越过";; esac

# ===== R7 控制格红 =====
mkleg "$W" normod
v=$(readout "$W" 1 1)
case "$v" in *"控制格"*) ok "R7 RMMOD 那格红 ⇒ $v" ;; *) no "R7 控制格红没体现(=$v) ⇒ 那两格没进裁判" ;; esac

# ===== R8 没有 END =====
mkleg "$W" noend
v=$(readout "$W" 1 0)
case "$v" in *"未测(读法①"*) ok "R8 READY=0 ⇒ $v" ;; *) no "R8 没等到读数却定性(=$v)" ;; esac

# ===== R9 腿的旧账不当裁判 =====
mkleg "$W" oldcount
v=$(readout "$W" 1 1)
case "$v" in 判正*REJUDGE*) ok "R9 腿自计 pass=13/fail=1 而现行表全等 ⇒ $v" ;; *) no "R9 重判被旧账带红(=$v) ⇒ 重判口径没生效" ;; esac
v=$(readout "$W" 0 1)
case "$v" in *"模型红"*|*"判正"*) no "R9 REJ=0 时旧账(pass=13≠$FULLPASS)必须不许判正(=$v)";; esac
ok "R9 两条路分开：REJ=1 按现行表重算＝判正；REJ=0 仍拿腿自计⇒判据不齐(已验)"

# ===== R10 真归档 × 真表(＝第 97 发的定性，可重跑) =====
if [ -s "$ARC" ]; then
  v=$(readout "$ARC" 1 1)
  case "$v" in 判正*) ok "R10 真归档重判 ⇒ $v" ;; *) no "R10 真归档重判没判正(=$v) ⇒ 模型或读法还有一处不对" ;; esac
  f=$(fullout "$ARC" 1 1)
  grep -q "六把全等的格=$ROWS/$ROWS" <<<"$f" || no "R10 真归档不是逐格全等(表行=$ROWS)"
  grep -q "⑥a(读数差)" <<<"$f" && no "R10 真归档里还有读数差 ⇒ 跨架构那一格没关上"
else
  no "R10 未跑：真归档不在($ARC) ⇒ 这一格记未测，不许当过"
fi

echo "=== 汇总：表行=$ROWS 满分=$FULLPASS 失败=$FAIL ==="
[ "$FAIL" = 0 ] && echo "PASS run_sepd_readout 十格全过(链的判读段：两支分岔＋want 摘尾＋重判口径都有牙)"
exit "$FAIL"
