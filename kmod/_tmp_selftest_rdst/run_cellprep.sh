#!/usr/bin/env bash
# run_cellprep.sh —— w427_cell_prep.sh 的两道"参数现取"闸的双向自测(不碰设备、不开窗)。
#   为什么要测它：2026-10-18 那一跑真机暴露了两个洞——
#     洞一：`grep -w package:com.termux` 把 `package:com.termux.api uid:10817` 也捞进来，
#           uid 取到两行 ⇒ 组装出的 DOM_MAP 中间夹一个换行，而"数条数=2"那道照样放行；
#           夹换行的串到了 go.sh 是 base64 铺成三行文件 ⇒ dom_for 的 `^uid ` 永远配不上
#           ⇒ 静悄悄少一条映射(比报错更坏)。
#     洞二：`预检通过：` 那句不看 fail 就打印 ⇒ 红项也念"通过"。
#   ★切片边界要有牙：切出来必须含被测行、不许把邻居段吞进来、锚不许只在注释里(例 127)。
#   ★夹具走的是真的 pm list packages -U 文本形状(带 u0a 前缀那类不在这格)。
set -u
cd "$(dirname "$0")/../.." || exit 1
W=$(mktemp -d)
nchk=0; nbad=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; nbad=1; fi; }

SRC=${SRC:-kmod/w427_cell_prep.sh}   # ★变异测试可以把 SRC 指到副本上，不必动真件
: > "$W/slice1.err"; : > "$W/slice3.err"
[ -r "$SRC" ] || { echo "[x] 被测脚本不在：$SRC"; exit 1; }

# ---------- 切片 1：section 1(uid 现取整段，含 declare -A U 与那条精确匹配) ----------
awk 'index($0,"=== 1) uid 现取"){f=1} index($0,"=== 2) 上下文串现取"){f=0} f' "$SRC" > "$W/slice1.sh"
grep -qF 'declare -A U' "$W/slice1.sh" || { echo "[x] 没切到 section 1(起点锚失效)"; exit 1; }
grep -qF 'grep -a "^package:$pkg uid:[0-9]*$"' "$W/slice1.sh" || { echo "[x] 切出来不含那条整行精确匹配 ⇒ 被测的那行不在夹具里"; exit 1; }
grep -qF 'grep -ac .' "$W/slice1.sh" || { echo "[x] 切出来不含「匹配到几条」那道闸"; exit 1; }
[ "$(grep -c 'pidof' "$W/slice1.sh")" = 0 ] || { echo "[x] 切片吞进 section 2 了(终点锚失效)"; exit 1; }

# ---------- 切片 2：section 3(组装 + 整串形状闸) ----------
awk 'index($0,"=== 3) 组装 DOM_MAP"){f=1} index($0,"=== 4) 下一步照贴"){f=0} f' "$SRC" > "$W/slice3.sh"
grep -qF 'SHAPE_OK=' "$W/slice3.sh" || { echo "[x] 没切到整串形状闸(这条就是洞一的补丁)"; exit 1; }
grep -qF 'tr -d -- ' "$W/slice3.sh" || { echo "[x] 字符白名单那道不在切片里"; exit 1; }
grep -qF '预检$( [ "$fail" = 0 ]' "$W/slice3.sh" || { echo "[x] 洞二(不看 fail 就念『通过』)没修进来"; exit 1; }
grep -qF 'TWO_SPEC="$TWO_UID:$TWO_PKG"' "$W/slice3.sh" || { echo "[x] 第二条记录的生产者(开关内容)不在切片里 ⇒ 这一格会静悄悄退成单条目"; exit 1; }
[ "$(grep -c 'monkey' "$W/slice3.sh")" = 0 ] || { echo "[x] 切片吞进 section 4 了"; exit 1; }
echo "切片行数：section1=$(wc -l < "$W/slice1.sh")  section3=$(wc -l < "$W/slice3.sh")"

# ---------- 跑切片 1：A() 打桩成"读夹具"，看 U[com.termux] 与 fail ----------
run_s1() { # $1=夹具文件(假 pm list packages -U 输出)
    FIX=$1
    ( A() { cat "$FIX"; }
      PKGS="com.suw.manager com.termux"
      fail=0
      eval "$(cat "$W/slice1.sh")" 2>>"$W/slice1.err"
      printf 'RES fail=%s termux=%s suw=%s\n' "$fail" "${U[com.termux]:-NONE}" "${U[com.suw.manager]:-NONE}"
    ) >"$W/s1.out" 2>&1
    cat "$W/s1.out"
    cat "$W/slice1.err"
}
mkfix() { printf '%s\n' "$@" > "$W/fix.txt"; echo "$W/fix.txt"; }

F=$(mkfix 'package:com.suw.manager uid:10342' 'package:com.termux uid:10667' 'package:android uid:1000')
O=$(run_s1 "$F")
chk "①正常两条：fail=0" "$(printf '%s' "$O" | grep -aq 'RES fail=0 ' && echo 1 || echo 0)"
chk "①正常两条：termux=10667" "$(printf '%s' "$O" | grep -aq 'termux=10667 ' && echo 1 || echo 0)"

F=$(mkfix 'package:com.suw.manager uid:10342' 'package:com.termux uid:10667' 'package:com.termux.api uid:10817')
O=$(run_s1 "$F")
chk "②★正对照(今天的洞)：同前缀包 com.termux.api 不许被捞进来" "$(printf '%s' "$O" | grep -aq 'RES fail=0 termux=10667 ' && echo 1 || echo 0)"
chk "②同前缀包：termux 的值里不许有换行/第二个数" "$(printf '%s' "$O" | grep -aq '10817' && echo 0 || echo 1)"
# ②b 反证：同一条夹具喂**旧写法**(grep -w)要真的捞到 2 条、喂新写法只 1 条——
#   不然这格只是在测空气(例 133：夹具的形状也要取真值)。
TWO=$(printf '%s\n' "$(cat "$F")" | grep -a -w "package:com.termux" | grep -ac .)
ONE=$(printf '%s\n' "$(cat "$F")" | grep -a "^package:com.termux uid:[0-9]*$" | grep -ac .)
chk "②b 旧写法在这条夹具上确实出 $TWO 条(=2)、新写法出 $ONE 条(=1) ⇒ ② 有牙" "$( [ "$TWO" = 2 ] && [ "$ONE" = 1 ] && echo 1 || echo 0)"

F=$(mkfix 'package:com.suw.manager uid:10342')
O=$(run_s1 "$F")
chk "③少一个包 ⇒ 必须红" "$(printf '%s' "$O" | grep -aq 'RES fail=1' && echo 1 || echo 0)"

F=$(mkfix 'package:com.suw.manager uid:10342' 'package:com.termux uid:10667' 'package:com.termux uid:10700')
O=$(run_s1 "$F")
chk "④同名两行 ⇒ 必须红(不能默选取第一条)" "$(printf '%s' "$O" | grep -aq 'RES fail=1' && echo 1 || echo 0)"

F=$(mkfix 'package:com.suw.manager uid:u0a342' 'package:com.termux uid:10667')
O=$(run_s1 "$F")
chk "⑤uid 不是纯数字 ⇒ 必须红" "$(printf '%s' "$O" | grep -aq 'RES fail=1' && echo 1 || echo 0)"

# ---------- 跑切片 2：直接喂 U/C，看组装与整串闸 ----------
run_s3() { # $1=U1 $2=C1 $3=U2 $4=C2
    ( PKGS="com.suw.manager com.termux"
      declare -A U C
      U[com.suw.manager]=$1; C[com.suw.manager]=$2
      U[com.termux]=$3;     C[com.termux]=$4
      fail=0
      eval "$(cat "$W/slice3.sh")" 2>>"$W/slice3.err"
      printf 'RES fail=%s map=%s\n' "$fail" "$MAP"
    ) >"$W/s3.out" 2>&1
    cat "$W/s3.out"
    cat "$W/slice3.err"
}
CTX1='u:r:untrusted_app:s0:c86,c257,c512,c768'
CTX2='u:r:untrusted_app_25:s0:c512,c768'
O=$(run_s3 10342 "$CTX1" 10667 "$CTX2")
chk "⑥两条真串 ⇒ 预检通过" "$(printf '%s' "$O" | grep -aqF "RES fail=0 map=10342=$CTX1;10667=$CTX2" && echo 1 || echo 0)"
chk "⑥预检通过 ⇒ 文案要说『通过』" "$(printf '%s' "$O" | grep -aqF '预检通过：DOM_MAP=10342=' && echo 1 || echo 0)"
chk "⑥第二条记录的内容要现算出来(开关 ksu_two_profiles＝10667:com.termux)" "$(printf '%s' "$O" | grep -aqF '=[10667:com.termux]' && echo 1 || echo 0)"
chk "⑥文案与状态同源：这一格绿时只能念『通过』" "$( [ "$(printf '%s' "$O" | grep -acF '预检通过')" = 1 ] && [ "$(printf '%s' "$O" | grep -acF '预检未通过')" = 0 ] && echo 1 || echo 0)"

NL=$'\n'   # ★不许写 NL=$(printf '\n')：命令替换会把行尾换行剥掉 ⇒ 夹具根本没换行 ⇒ 这格在测空气(例 133)
BADUID="10667${NL}10817"
chk "⑦夹具自证：喂进去的那条 uid 真带一个换行(wc -l=1)" "$( [ "$(printf '%s' "$BADUID" | wc -l)" = 1 ] && echo 1 || echo 0)"
O=$(run_s3 10342 "$CTX1" "$BADUID" "$CTX2")
chk "⑦★负对照(今天的洞原样回放)：uid 夹换行 ⇒ 整串形状闸必须红" "$(printf '%s' "$O" | grep -aq 'RES fail=1' && echo 1 || echo 0)"
chk "⑦红项文案只能写『未通过』" "$(printf '%s' "$O" | grep -aqF '预检未通过' && ! printf '%s' "$O" | grep -aqF '预检通过' && echo 1 || echo 0)"
chk "⑦红是**形状闸**报的；字符白名单那道对换行是盲的(BAD 里换行被 \$() 剥光) ⇒ 不许拿它当唯一闸" "$(printf '%s' "$O" | grep -aqF '整串形状不合格' && ! printf '%s' "$O" | grep -aqF '含非法字符' && echo 1 || echo 0)"

O=$(run_s3 10342 "$CTX1" '' '')
chk "⑧只有一条 ⇒ 必须红" "$(printf '%s' "$O" | grep -aq 'RES fail=1 map=10342' && echo 1 || echo 0)"
chk "⑧红的原因要点名『追加条目没 uid』(不许只靠形状闸顺带拦住)" "$(printf '%s' "$O" | grep -aqF '追加条目要的 com.termux 没读到 uid' && echo 1 || echo 0)"

O=$(run_s3 10342 "u:r:untrusted app:s0" 10667 "$CTX2")
chk "⑨上下文串夹空格 ⇒ 必须红" "$(printf '%s' "$O" | grep -aq 'RES fail=1' && echo 1 || echo 0)"

O=$(run_s3 10342 "u:r:app'; rm -rf #s0" 10667 "$CTX2")
chk "⑩串里带单引号/分号外的怪字符 ⇒ 必须红(这串最终要被贴进命令行)" "$(printf '%s' "$O" | grep -aq 'RES fail=1' && echo 1 || echo 0)"

O=$(run_s3 10342 "$CTX1" 10667 "$CTX1")
chk "⑪两串相同 ⇒ 只给提醒(不算红)，形状闸放行" "$(printf '%s' "$O" | grep -aq 'RES fail=0' && printf '%s' "$O" | grep -aqF '两串相同' && echo 1 || echo 0)"

# ---------- 切片本身不许把工具报错咽进去 ----------
chk "⑫两遍 eval 里没有出现语法/命令类报错文本" "$( { grep -aqE 'syntax error|command not found|unrecognized|invalid arithmetic|bad array subscript' "$W/slice1.err" "$W/slice3.err" 2>/dev/null && echo 0 || echo 1; } )"
[ "$nbad" = 0 ] && echo "=== run_cellprep：$nchk 项全绿 PASS(夹具见 $W) ===" || echo "=== run_cellprep：$nchk 项里有红 FAIL(见上) 目录=$W ==="
[ "$nbad" = 0 ]
