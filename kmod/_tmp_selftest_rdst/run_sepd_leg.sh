#!/usr/bin/env bash
# run_sepd_leg.sh —— w1152 那条"核内解码预演腿"的离线自测(0 枪，不碰设备)。
#   ★为什么要它：这条腿要在**一发窗**里才第一次真跑，而历史上"腿里读数的取法/比对写错"是把枪白白烧掉的
#     头号原因(第 69/70/91/92 发)。⇒ 上机之前，把腿里那几段**原样抽出来**在 PC 上喂给它自己造的读数。
#   ★"原样抽出"＝从腿里现抽(不是我另抄一份)；抽不出来或抽太少就红 ⇒ 改了腿会逼着改这里。
#   七格：
#     G1 静态牙：腿里该有的三段都在，抽出来的字节数过线
#     G2 分组：表里 slots 值必须恰好是 {4369, 8}(变体那一组不能丢)
#     G3 配对：主组 11 格＋变体 1 格，且 case/file 用 cut 拆得回来(文件名带点)
#     G4 取键：对真实表的一行，八个键全取到且与"手算证人 md5"对得上
#     G5 反夹具：给一行缺键的表，取键必须给空 ⇒ 腿里"缺键判坏"那把闸是可达的(不是恒非空)
#     G6 比对核：读数全等 ⇒ ok=1；四条各差一点的变异 ⇒ ok=0(why/n/md5/fnv)
#     G7 渲染核对：why≠0 时 rec_stmts 必须 0；why=0 且未截断时必须等于 n
set -u
cd "$(dirname "$0")/../.." || exit 9
LEG=kmod/w1152_sepd_leg.sh
TBL=kmod/w1152_fixtures/expect.txt
BLK=kmod/_tmp_selftest_rdst/block_sepd_compare.sh
FAIL=0
ok() { echo "[OK] $*"; }
no() { echo "[!!] $*"; FAIL=1; }

[ -f "$LEG" ] || { no "腿不在：$LEG"; exit 1; }
[ -f "$TBL" ] || { no "期望表不在：$TBL(先跑 python kmod/w1152_sepd_fixtures.py)"; exit 1; }

# ===== G1 静态牙：三段"读数的取法"必须还在腿里，且比对核能抽出来 =====
grep -q 'kv()  { sed -n "s/\.\* \$1=\\(\[^ ]\*\\)\.\*/\\1/p" | head -1; }' "$LEG" \
  || no "kv 的定义变了 ⇒ 这里的抽取也要跟着变"
grep -q 'SLOTGRP=$(awk ' "$LEG" || no "分组那行没了(读法被删？)"
grep -q 'for pair in $(awk ' "$LEG" || no "case/file 配对那行没了"
# 抽比对核：从 `ok=1` 到 `if [ "$ok" = 1 ]` 之前(不含)
awk '/^  ok=1$/{f=1} /^  if \[ "\$ok" = 1 \]/{f=0} f{print}' "$LEG" > "$BLK"
CB=$(wc -c <"$BLK"); CL=$(wc -l <"$BLK")
[ "$CL" -ge 12 ] || no "抽出的比对核只有 $CL 行(应当≥12)⇒ 锚点错了，后面 G6 是在跑空气"
[ "$CB" -gt 200 ] || no "抽出的比对核只有 $CB 字节 ⇒ 同上"
[ "$FAIL" = 0 ] && ok "G1 静态牙：三段都在，比对核抽出 $CL 行/$CB 字节"

# ===== G2 分组(用腿里那条 awk 的原样程序文本) =====
AWK_G=$(grep -o "awk '!/^#/ { for(i=1;i<=NF;i++) if(\$i ~ /^slots=/) print substr(\$i,7) }" "$LEG" | head -1)
[ -n "$AWK_G" ] || { no "G2 抽不出分组那条 awk 程序(腿里的写法变了)"; }
# ★★这一格第一版是红的，红因值得留档：我把变量写成 `GROUPS`，而 **bash 4.4+ 把 GROUPS 当保留数组**
#   (进程的有效组 ID)，给它赋值会被**无声忽略** ⇒ 读到的是 `[197121]` 这种组号，不是我的分组。
#   腿本身跑在 mksh(没这问题)，但同名就是隐患 ⇒ 两边一起改名 SLOTGRP，并在腿里写了这条注释。
AWK_G=$(grep -o "awk '!/^#/ { for(i=1;i<=NF;i++) if(\$i ~ /^slots=/) print substr(\$i,7) }" "$LEG" | head -1)
[ -n "$AWK_G" ] || no "G2 抽不出分组那条 awk 程序(腿里的写法变了)"
SLOTGRP=$(eval "awk '!/^#/ { for(i=1;i<=NF;i++) if(\$i ~ /^slots=/) print substr(\$i,7) }'" "$TBL" | sort -u | tr '\n' ' ')
[ "$SLOTGRP" = "4369 8 " ] && ok "G2 分组=[$SLOTGRP](主组＋变体组都在)" || no "G2 分组=[$SLOTGRP] 期望 '4369 8 '"

# ===== G3 配对：主组 11 格、变体 1 格，且 case/file 拆得回来 =====
pairsof() { awk -v s="$1" '!/^#/ { sl=""; fl=""; for(i=1;i<=NF;i++){ if($i ~ /^slots=/) sl=substr($i,7); if($i ~ /^file=/) fl=substr($i,6) } if(sl==s) print $1 "." fl }' "$TBL"; }
P4369=$(pairsof 4369 | wc -l | tr -d ' ')
P8=$(pairsof 8 | tr '\n' ' ')
[ "$P4369" = 11 ] && ok "G3 主组 11 格(正 4＋破 7)" || no "G3 主组格数=$P4369 应为 11"
[ "$P8" = "ok9s8.ok9.bin " ] && ok "G3 变体组=[$P8]" || no "G3 变体组=[$P8] 应为 ok9s8.ok9.bin"
for pair in bad_cmd.bad_cmd.bin ok9s8.ok9.bin; do
  c=$(echo "$pair" | cut -d. -f1); f=$(echo "$pair" | cut -d. -f2-)
  [ -n "$c" ] && [ -n "$f" ] && [ -f "kmod/w1152_fixtures/$f" ] && ok "G3 拆名 $pair ⇒ case=$c file=$f(件在)" \
    || no "G3 拆名 $pair ⇒ case=$c file=$f 或件不在"
done

# ===== G4 取键：拿腿里那句 kv 的原样定义跑真实表 =====
kv()  { sed -n "s/.* $1=\([^ ]*\).*/\1/p" | head -1; }
L1=$(grep '^ok1 ' "$TBL" | head -1)
[ -n "$L1" ] || { no "G4 表里没有 ok1 那一行"; }
for k in file bytes md5 fnv slots why n bad_at max_arg lenmatch; do
  v=$(echo "$L1" | kv "$k")
  [ -n "$v" ] || no "G4 键 $k 取到空(行=[$L1])"
done
V_MD5=$(echo "$L1" | kv md5); V_WHY=$(echo "$L1" | kv why); V_N=$(echo "$L1" | kv n)
V_AT=$(echo "$L1" | kv bad_at); V_MA=$(echo "$L1" | kv max_arg); V_LM=$(echo "$L1" | kv lenmatch)
V_BYTES=$(echo "$L1" | kv bytes); V_FNV=$(echo "$L1" | kv fnv)
# 手算证人：那条 49 字节的 allow 流(与 w1151 的 C 数组、w1152 的 python 编码器三处同形)
[ "$V_MD5" = "4bbad6252af47c1ac78397726bbe5af0" ] || no "G4 ok1 的 md5=$V_MD5 ≠ 手算证人那份 ⇒ 线格式被谁改了"
{ [ "$V_BYTES" = 49 ] && [ "$V_WHY" = 0 ] && [ "$V_N" = 1 ] && [ "$V_AT" = 0 ] \
  && [ "$V_MA" = 10 ] && [ "$V_LM" = 1 ]; } || no "G4 ok1 的期望不齐(bytes=$V_BYTES why=$V_WHY n=$V_N at=$V_AT ma=$V_MA lm=$V_LM)"
[ "$FAIL" = 0 ] && ok "G4 取键十把全中，且 ok1 的 md5 与手算证人一致(md5=$V_MD5 fnv=$V_FNV)"

# ===== G5 反夹具：缺键必须取到空(腿里"缺键判坏"那把闸要可达) =====
BADL="only1 file=x.bin bytes=49 md5=abc why=0"
[ -z "$(echo "$BADL" | kv bad_at)" ] || no "G5 缺 bad_at 却取到了值 ⇒ 腿里那把'期望缺键'的闸是恒绿的"
[ -z "$(echo "nothing here" | kv md5)" ] || no "G5 空行却取到 md5 ⇒ 同上"
ok "G5 反夹具：缺键取到空(腿里的判坏分支可达)"

# ===== G6 比对核：把期望从**真实表的某一行**载入，读数由我喂 =====
load_expect() { # load_expect <case名>：把那一行的八个期望装进 E_*
  local l; l=$(grep "^$1 " "$TBL" | head -1)
  [ -n "$l" ] || { no "表里没有 $1 那一行"; return 1; }
  E_BYTES=$(echo "$l" | kv bytes); E_MD5=$(echo "$l" | kv md5); E_FNV=$(echo "$l" | kv fnv)
  E_WHY=$(echo "$l" | kv why); E_N=$(echo "$l" | kv n); E_AT=$(echo "$l" | kv bad_at)
  E_MA=$(echo "$l" | kv max_arg); E_LM=$(echo "$l" | kv lenmatch)
  for v in "$E_BYTES" "$E_MD5" "$E_FNV" "$E_WHY" "$E_N" "$E_AT" "$E_MA" "$E_LM"; do
    [ -n "$v" ] || { no "$1 那行取到空键(=$l)"; return 1; }
  done
  return 0
}
run_core() { # run_core <r_why r_n r_at r_ma r_lm r_bytes r_sum r_md5 r_stmts r_trunc>
  set -- "$@"
  w_why="$E_WHY"; w_n="$E_N"; w_at="$E_AT"; w_ma="$E_MA"; w_lm="$E_LM"
  w_bytes="$E_BYTES"; w_fnv="$E_FNV"; w_md5="$E_MD5"
  r_why="$1"; r_n="$2"; r_at="$3"; r_ma="$4"; r_lm="$5"; r_bytes="$6"; r_sum="$7"; r_md5="$8"; r_stmts="$9"; r_trunc="${10}"
  . "$BLK"
  printf '%s' "$ok"
}
# 正对照：读数＝期望(用 ok1 那一行)
load_expect ok1
GOOD=$(run_core "$E_WHY" "$E_N" "$E_AT" "$E_MA" "$E_LM" "$E_BYTES" "$E_FNV" "$E_MD5" 1 0)
[ "$GOOD" = 1 ] && ok "G6 正对照：读数与期望全等 ⇒ ok=1" || no "G6 正对照没给 1(=$GOOD) ⇒ 比对核写坏了"
# 八条变异：每个只把一个读数挪开(其余仍等于期望)⇒ 必须红
for tag in why n at ma lm bytes sum md5; do
  case $tag in
    why)   r="1 $E_N $E_AT $E_MA $E_LM $E_BYTES $E_FNV $E_MD5 1 0" ;;
    n)     r="0 2 $E_AT $E_MA $E_LM $E_BYTES $E_FNV $E_MD5 1 0" ;;
    at)    r="0 $E_N 9 $E_MA $E_LM $E_BYTES $E_FNV $E_MD5 1 0" ;;
    ma)    r="0 $E_N $E_AT 99 $E_LM $E_BYTES $E_FNV $E_MD5 1 0" ;;
    lm)    r="0 $E_N $E_AT $E_MA 0 $E_BYTES $E_FNV $E_MD5 1 0" ;;
    bytes) r="0 $E_N $E_AT $E_MA $E_LM 48 $E_FNV $E_MD5 1 0" ;;
    sum)   r="0 $E_N $E_AT $E_MA $E_LM $E_BYTES 999 $E_MD5 1 0" ;;
    md5)   r="0 $E_N $E_AT $E_MA $E_LM $E_BYTES $E_FNV deadbeef 1 0" ;;
  esac
  got=$(run_core $r)
  if [ "$got" = 0 ]; then ok "G6 变异[$tag 差一点] ⇒ ok=0(核有牙)"; else no "G6 变异[$tag] 没翻红(=$got) ⇒ 那把尺恒绿"; fi
done

# ===== G7 渲染核对：三条都得从**它自己那一行**的期望出发，别把"对不上"记到别的尺头上 =====
load_expect bad_cmd
R0=$(run_core "$E_WHY" "$E_N" "$E_AT" "$E_MA" "$E_LM" "$E_BYTES" "$E_FNV" "$E_MD5" 0 0)
[ "$R0" = 1 ] && ok "G7 拒收正对照：why≠0 且 rec_stmts=0 ⇒ 绿(对)" || no "G7 拒收正对照没绿(=$R0) ⇒ 渲染那一条把拒收件也当违规"
R1=$(run_core "$E_WHY" "$E_N" "$E_AT" "$E_MA" "$E_LM" "$E_BYTES" "$E_FNV" "$E_MD5" 5 0)
[ "$R1" = 0 ] && ok "G7 拒收却印了 5 行 STMT ⇒ 核判红(对)" || no "G7 拒收却印了 STMT 却没红 ⇒ 渲染那条对不上账"
load_expect ok600
R2=$(run_core "$E_WHY" "$E_N" "$E_AT" "$E_MA" "$E_LM" "$E_BYTES" "$E_FNV" "$E_MD5" 600 0)
[ "$R2" = 1 ] && ok "G7 收下且未截断：rec_stmts==n(600) ⇒ 绿(对)" || no "G7 收下且 rec_stmts==n 却红(=$R2)"
R3=$(run_core "$E_WHY" "$E_N" "$E_AT" "$E_MA" "$E_LM" "$E_BYTES" "$E_FNV" "$E_MD5" 500 1)
[ "$R3" = 1 ] && ok "G7 收下但截断：印了 500/600 且 rec_trunc=1 ⇒ 绿(对)" || no "G7 截断分支判错(=$R3)"
R4=$(run_core "$E_WHY" "$E_N" "$E_AT" "$E_MA" "$E_LM" "$E_BYTES" "$E_FNV" "$E_MD5" 600 1)
[ "$R4" = 0 ] && ok "G7 说截断了却把 600 条全印了 ⇒ 核判红(对)" || no "G7 截断自相矛盾却没红(=$R4)"
R5=$(run_core "$E_WHY" "$E_N" "$E_AT" "$E_MA" "$E_LM" "$E_BYTES" "$E_FNV" "$E_MD5" 599 0)
[ "$R5" = 0 ] && ok "G7 收下、未截断、但少印一条 ⇒ 核判红(对)" || no "G7 少印一条没红(=$R5) ⇒ 计数那把尺钝了"

echo "SEPD_LEG_SELFCHECK rc=$FAIL (抽出核=$CL 行；表行=$(grep -vc '^#' "$TBL"))"
# ★总闸 w413 的 item() 有三道：rc=0／证据行≥min／**还要有它自己那句 PASS**。
#   只印 rc 与计数不够——数到 23 条也可能全是红。⇒ 这句要在 FAIL=0 时才印。
[ "$FAIL" = 0 ] && echo "PASS run_sepd_leg 七格全过(G1 静态牙／G2 分组／G3 配对拆名／G4 十把取键＋手算证人／G5 缺键反夹具／G6 正对照＋八条单键变异／G7 渲染核六形)"
[ "$FAIL" = 0 ] || exit 1
exit 0
