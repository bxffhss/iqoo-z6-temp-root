#!/bin/bash
# w458_selftest_uinput.sh —— 把 kmod/ui_grant.sh 里"往官方搜索框放过滤词"那一腿切出来，离线跑夹具，双向验。
# 为什么要有这条腿：#147 那四轮失败里**闸是对的、判据也是对的，错的是"往有字的字段上再打一遍"**；
#   这种形状不开枪看不出来(它要真输入法 + 真字段)，但修好之后**每一支都能离线定死**：
#   ①证不出字段为空 ⇒ 必须**一条字都不打**(反例＝老形状：清空失败照样打字 ⇒ merge)；
#   ②读数只是期望值的前缀 ⇒ 必须**重读**而不是重打(重打就是再制造一次相粘)；
#   ③读数含过滤词但更长 ⇒ 判**不过**(搜索框拿整串做子串匹配，多一个字符列表就空了，"含有"不算过)；
#   ④过滤词是从包名剥出来的**最长 [a-z0-9] 段**(带点的整包名是成因，实测 com.termux 每轮漏尾巴、纯字母 4/4 干净)；
#   ⑤任何"没点"的断言都配一格"该点时 >0"的正对照(例 142)，任何计数都由脚本自己现数(例 127)。
# 夹具的来源：真产物 kmod/w103_evidence/ug_srch.xml(第 33 发窗口里那份，字段读数就是 [uxer]) ——
#   只改那一个 text 属性造出各种形状，别的节点/坐标一律原样(避免"夹具和我都按同一个错假设长"，例 129)。
set -u
cd "$(dirname "$0")/.." || exit 1
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8      # GBK 控制台遇到 '⇒' 会把 print 打崩(第 110 发真崩)
fail=0; nchk=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

SRC=$PWD/kmod/ui_grant.sh          # ★下面每个格子都要在 cd 进临时目录之后还引用得到切片与夹具 ⇒ 一律绝对路径
REAL=$PWD/kmod/w103_evidence/w458_srctree.xml   # ★冻结件！以前指 ug_srch.xml——那是 ui_grant 每跑一次就覆盖的活路径，第 35 发把"读出 [uxer] 的那一份"冲掉了（例 110 同族：证据路径一个名字只服务一个来源）。这份是第 35 发真机过滤后列表树的快照(101 节点，含 Clean/取消)。
W=$PWD/kmod/_tmp_w458
[ -s "$SRC" ] || { echo "[x] 读不到 $SRC"; exit 1; }
[ -s "$REAL" ] || { echo "[x] 读不到真产物 $REAL(第⑫格没有证人，别用我自己的夹具自证)"; exit 1; }
rm -rf "$W"; mkdir -p "$W/ev" "$W/fix" || exit 1

echo "=== ① 切片：七个零件逐个按函数名切，切不到就硬退出(别把『切片空』读成『形状没问题』) ==="
: > "$W/legs.sh"
for fn in pick_term is_empty_field field_now prove_empty type_term_once refocus_field srch_state ime_probe ime_cleanup; do
    n=$(awk -v F="$fn" '$0 ~ "^"F"\\(\\) \\{" {f=1} f {print} f && /^\}/ {f=0; exit}' "$SRC" | grep -ac .)
    [ "$n" -ge 3 ] || { echo "[x] $fn 只切到 $n 行 ⇒ 锚点失效(ui_grant.sh 里那个函数没了或改了名)"; exit 1; }
    awk -v F="$fn" '$0 ~ "^"F"\\(\\) \\{" {f=1} f {print} f && /^\}/ {f=0; exit}' "$SRC" >> "$W/legs.sh"
    echo "    $fn 切到 $n 行"
done
grep -aqF 'S "input text \"$TERM\""' "$W/legs.sh" || { echo "[x] 切片里没有『input text \$TERM』⇒ 打的还是整包名？"; exit 1; }

echo "=== ② 夹具：从真产物只改字段那一个 text ==="
python - "$REAL" "$W/fix" <<'PY'
import io, os, re, sys
src, outdir = sys.argv[1], sys.argv[2]
s = io.open(src, encoding='utf-8', errors='replace').read()
# 真树里"字段文本"就是那个 y<320 的 clickable 节点上的 text；先确认它在文件里唯一，否则夹具会改到别人身上
# 字段节点按**几何+角色**现认(可点、顶栏 y<=320、不是 Clean、不是取消)，不靠某个字面文本唯一：
#   快照里那句文本取决于当次跑，写死它＝把夹具绑在一次性的读数上(上一条就是这么把自己判废的)。
cand = []
for m in re.finditer(r'<node[^>]*', s):
    t = m.group(0)
    if 'clickable="true"' not in t:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', t)
    if not b or int(b.group(4)) > 320:
        continue
    mt = re.search(r'text="([^"]*)"', t)
    mc = re.search(r'content-desc="([^"]*)"', t)
    tv = mt.group(1) if mt else ''
    if (mc.group(1) if mc else '') == 'Clean' or tv in ('', '取消'):
        continue
    cand.append((m.start(), m.end(), tv))
if len(cand) != 1:
    print('[x] 这份树里能当字段的节点有 %d 个(须恰好 1) ⇒ 快照不是搜索态那棵树，不造夹具' % len(cand)); sys.exit(1)
if 'content-desc="Clean"' not in s or '取消' not in s:
    print('[x] 快照里没有 Clean/取消 ⇒ 不是官方搜索态的树，别拿它当证人'); sys.exit(1)
ST, EN, FTV = cand[0]


def variant(v):
    node = s[ST:EN]
    return s[:ST] + node.replace('text="%s"' % FTV, 'text="%s"' % v, 1) + s[EN:]


variants = {'empty': '', 'ph': '搜索', 'ok': 'termux', 'pre': 'term', 'merge': 'termuxux',
            'junk': 'ux', 'rot': 'xutrme', 'unkbase': '搜超级用户',
            'q': 'q', 'fw': '。'}   # ★#169 探针用的两份：能直接提交的 q／全角句号
for k, v in variants.items():
    io.open(os.path.join(outdir, k + '.xml'), 'w', encoding='utf-8').write(variant(v))
# 再加一份"字段非空且没有 Clean 键"：这一格专测『读不到键就不点，但退格照跑』
io.open(os.path.join(outdir, 'ncjunk.xml'), 'w', encoding='utf-8').write(
    variant('ux').replace('content-desc="Clean"', 'content-desc="Xlean"', 1))
io.open(os.path.join(outdir, 'real.xml'), 'w', encoding='utf-8').write(s)
print('    造了 %d 份夹具(字段节点按几何现认，恰好 1 个；快照原字段=[%s])' % (len(variants) + 2, FTV))
PY
[ -s "$W/fix/ok.xml" ] || { echo "[x] 夹具没造出来"; exit 1; }
NREAL=$(grep -ac . "$W/fix/ok.xml")
chk "②夹具里有真产物那棵树(行数=$NREAL)且字段文本被换掉而 Clean/取消 节点还在" \
    "$(grep -aq 'content-desc="Clean"' "$W/fix/ok.xml" && grep -aq '取消' "$W/fix/ok.xml" && grep -aq 'text="termux"' "$W/fix/ok.xml" && echo 1 || echo 0)"

# 跑一腿：$1=格名 $2=TERM 其余=夹具名序列(用尽后重复最后一个)
run() {
  local name=$1 T=$2; shift 2
  : > "$W/log_$name.txt"; : > "$W/calls_$name.log"; echo 0 > "$W/n_$name"
  : > "$W/seq_$name"; local f; for f in "$@"; do echo "$W/fix/$f.xml" >> "$W/seq_$name"; done
  (
    cd "$W" || exit 1
    EV="$W/ev"; PY=python; TERM="$T"; WORD="$T"; WANT_PKG=com.termux; FIELD_LAST=""
    UGBASE="${RUN_UG:-}"; BASE_OK="${RUN_BASEOK:-0}"   # ★和出货件里那两个全局同名：第一次打字才允许"回到进来时的形状"
    S()   { printf 'S|%s\n' "$1" >> "$W/calls_$name.log"; return 0; }
    adb() { printf 'A|%s\n' "$*" >> "$W/calls_$name.log"; return 0; }
    sleep() { :; }
    dump_to() {
      local i n f
      i=$(($(cat "$W/n_$name") + 1)); echo $i > "$W/n_$name"
      n=$(grep -ac . "$W/seq_$name"); f=$(sed -n "${i}p" "$W/seq_$name")
      [ -n "$f" ] || f=$(tail -1 "$W/seq_$name")
      cp "$f" "$1"
    }
    source "$W/legs.sh"
    if prove_empty; then
      if type_term_once; then echo "OUT=ok"; else echo "OUT=retry"; fi
    else
      echo "OUT=nclean"
    fi
    echo "DUMPS=$(cat "$W/n_$name")"
  ) > "$W/log_$name.txt" 2>&1
}
ncall() { grep -ac "$2" "$W/calls_$1.log" | tr -dc '0-9'; }
out()   { grep -a '^OUT=' "$W/log_$1.txt" | tail -1 | cut -d= -f2; }

echo "=== ③ 好走那一支：字段本来是空的 ⇒ 打一次就逐字对上 ==="
run good termux empty ok
chk "③结果=ok(逐字对上)" "$([ "$(out good)" = ok ] && echo 1 || echo 0)"
chk "③只打了 1 串字(实得 $(ncall good '^S|input text'))＝正对照：该打时确实 >0" \
    "$([ "$(ncall good '^S|input text')" = 1 ] && echo 1 || echo 0)"

echo "=== ④ 反例①：字段证不出是空的 ⇒ 必须一条字都不打(老形状就是在这里叠字造出 merge) ==="
run refuse termux junk junk
chk "④结果=nclean(证空失败)" "$([ "$(out refuse)" = nclean ] && echo 1 || echo 0)"
chk "④这一格 input text 次数=0(实得 $(ncall refuse '^S|input text'))" \
    "$([ "$(ncall refuse '^S|input text')" = 0 ] && echo 1 || echo 0)"
chk "④且打印了『退格一条都没落地』那条警告(读数一字没变＝腿坏了，不能读成『字段不为空』)" \
    "$(grep -aq '退格这条腿可能没落到字段上' "$W/log_refuse.txt" && echo 1 || echo 0)"

echo "=== ⑤ 异步尾巴：第一轮退格跑在还没落地的尾巴之前 ⇒ 第二轮必须还能再清 ==="
run tworound termux junk empty empty ok
chk "⑤第二轮清干净了(结果=ok)" "$([ "$(out tworound)" = ok ] && echo 1 || echo 0)"
chk "⑤日志里真有『证空第 2 轮』(没有第二轮这条腿就是摆设)" \
    "$(grep -aq '证空第 2 轮' "$W/log_tworound.txt" && echo 1 || echo 0)"

echo "=== ⑥ 前缀＝键还没落地 ⇒ 只重读，不重打 ==="
run prefix termux empty pre pre ok
chk "⑥最后逐字对上(结果=ok)" "$([ "$(out prefix)" = ok ] && echo 1 || echo 0)"
chk "⑥全程只打 1 串字(实得 $(ncall prefix '^S|input text'))＝重读不是重打" \
    "$([ "$(ncall prefix '^S|input text')" = 1 ] && echo 1 || echo 0)"
ND=$(grep -a '^DUMPS=' "$W/log_prefix.txt" | cut -d= -f2)
chk "⑥但读了 $ND 次(>3＝确实等了两次才走)＝正对照组，防『计数=0 全绿』" \
    "$([ "${ND:-0}" -ge 4 ] && echo 1 || echo 0)"

echo "=== ⑦ 含过滤词但更长＝相粘：判不过(搜索框拿整串匹配，多一个字符列表就空) ==="
run merge termux empty merge
chk "⑦结果=retry(不许把 merge 判成过)" "$([ "$(out merge)" = retry ] && echo 1 || echo 0)"
chk "⑦成因那行写的是『粘了别的东西』" "$(grep -aq '粘了别的东西' "$W/log_merge.txt" && echo 1 || echo 0)"
chk "⑦这一格只打了一次(没过也不许顺手再打)" "$([ "$(ncall merge '^S|input text')" = 1 ] && echo 1 || echo 0)"

echo "=== ⑧ 没有 Clean 键那一形状：不许点 Clean，但退格这条腿照跑 ==="
run nclean termux ncjunk ncjunk
chk "⑧没点到 Clean(树里读不到键就一个点都不发，实得 input tap $(ncall nclean '^S|input tap') 次)" \
    "$([ "$(ncall nclean '^S|input tap')" = 0 ] && echo 1 || echo 0)"
chk "⑧但退格照跑(那条命令里 keyevent 67 出现 $(ncall nclean 'keyevent 67') 行>0)" "$([ "$(ncall nclean 'keyevent 67')" -gt 0 ] && echo 1 || echo 0)"
chk "⑧这一格也没往证不出为空的字段上打字(input text=0)" "$([ "$(ncall nclean '^S|input text')" = 0 ] && echo 1 || echo 0)"
chk "⑧退格是**本机拼好的一行**(远端不许出现 for/seq 那种由别的壳解释的形状)"     "$(grep -v '^[[:space:]]*#' "$SRC" | grep -q 'for i in \$(seq' && echo 0 || echo 1)"

echo "=== ⑨ 过滤词是从包名剥出来的最长 [a-z0-9] 段(★带点的整包名就是成因) ==="
forpair() { # $1=WORD $2=WANT_PKG $3=期望 TERM
  ( cd "$W"; EV="$W/ev"; PY=python; WORD="$1"; WANT_PKG="$2"; source "$W/legs.sh"; pick_term )
}
chk "⑨com.termux -> termux(实得 $(forpair com.termux com.termux))" \
    "$([ "$(forpair com.termux com.termux)" = termux ] && echo 1 || echo 0)"
chk "⑨suprobe/com.suprobe.app -> suprobe(不是 'app' 那种谁都在的段，实得 $(forpair suprobe com.suprobe.app))" \
    "$([ "$(forpair suprobe com.suprobe.app)" = suprobe ] && echo 1 || echo 0)"
chk "⑨me.weishu.kernelsu -> kernelsu(实得 $(forpair me.weishu.kernelsu me.weishu.kernelsu))" \
    "$([ "$(forpair me.weishu.kernelsu me.weishu.kernelsu)" = kernelsu ] && echo 1 || echo 0)"
chk "⑨com.termux.api -> termux(不是 'api'，实得 $(forpair com.termux.api com.termux.api))" \
    "$([ "$(forpair com.termux.api com.termux.api)" = termux ] && echo 1 || echo 0)"
chk "⑨整串都是标点时剥出空串(空串这一支在走路里是『不打字直接作废』，见第⑩条静态牙)" \
    "$([ "$(forpair 'com' 'com')" = com ] && [ -z "$(forpair '..' '..')" ] && echo 1 || echo 0)"

echo "=== ⑩ 静态牙：顺序、判据形状、空串退回 ==="
chk "⑩打字发生在证空之后(源码里就是 prove_empty && type_term_once，不许反过来)" \
    "$(grep -q 'if prove_empty && type_term_once; then' "$SRC" && echo 1 || echo 0)"
chk "⑩验收判据是逐字相等 [ \"\$F\" = \"\$TERM\" ]，不是『含有』" \
    "$(grep -q '\[ "$F" = "$TERM" \] && { echo "    字段逐字' "$SRC" && echo 1 || echo 0)"
chk "⑩空过滤词那一支先『不打字』再作废(退回话里就有『不打字』)" \
    "$(grep -q '剥出来是空串 ⇒ 不打字，本轮作废' "$SRC" && echo 1 || echo 0)"
chk "⑩字段中心是**现量**的(build_ug_fld.txt 由 srch_state 从树里写出来，不是第二个写死坐标)" \
    "$(grep -q "fxy='%d %d' % (cx,cy)" "$SRC" && grep -q 'build_ug_fld.txt' "$SRC" && echo 1 || echo 0)"
chk "⑩重焦点只敲整数坐标(非整数一律不点)——反例见第⑪条" \
    "$(grep -q 'if \[\[ "$FX" =~ ^\[0-9\]+\$ && "$FY" =~ ^\[0-9\]+\$ \]\]; then S "input tap $FX $FY"' "$SRC" && echo 1 || echo 0)"

echo "=== ⑪ refocus_field 的三格(有效坐标/坏坐标/没坐标) ==="
refoc() { # $1=写进 build_ug_fld.txt 的内容
  ( cd "$W"; printf '%s' "$1" > build_ug_fld.txt
    S() { echo "R|$1" >> "$W/refoc.log"; }; sleep() { :; }
    source "$W/legs.sh"; refocus_field >/dev/null 2>&1 )
}
: > "$W/refoc.log"; refoc "120 340"; A=$(grep -ac '^R|input tap 120 340' "$W/refoc.log" | tr -dc '0-9')
refoc "abc def"; B=$(grep -ac '^R|input tap' "$W/refoc.log" | tr -dc '0-9')
refoc "";        C=$(grep -ac '^R|input tap' "$W/refoc.log" | tr -dc '0-9')
chk "⑪有效坐标点了 1 次(正对照，实得 $A)" "$([ "$A" = 1 ] && echo 1 || echo 0)"
chk "⑪坏坐标一条都不点(否则就是把中文句子喂给 input tap——第 111 发的失败朝开) 实得累计 $B/$C" \
    "$([ "$B" = 1 ] && [ "$C" = 1 ] && echo 1 || echo 0)"

echo "=== ⑫ 真产物回归：那份把窗口烧了四轮的 ug_srch.xml 必须被读成 [uxer] ==="
( cd "$W"; cp "$REAL" ev/ug_srch.xml; EV="$W/ev"; PY=python; source "$W/legs.sh"; srch_state > realout.txt 2>&1 )
chk "⑫**真树**(第 35 发快照)的字段读数=termux(⇒ 抽取腿认得真树，不只认我自己的夹具)" \
    "$(grep -aq '字段=\[termux\]' "$W/realout.txt" && echo 1 || echo 0)"
chk "⑫真树的 Clean 坐标是整数对(第 111 发那句『Clean 在 content-desc 里』还在生效)" \
    "$(awk '{ if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/) ok=1 } END { exit ok?0:1 }' "$W/build_ug_clean.txt" && echo 1 || echo 0)"

echo "=== ⑬a 没见过的占位符：第一次打字必须能走(把"我不知道"写成"不行"＝这条腿在官方框上一步都走不动) ==="
RUN_UG='搜超级用户' RUN_BASEOK=1 run unkbase termux unkbase ok
chk "⑬a 结果=ok(读数逐字等于过滤词)" "$([ "$(out unkbase)" = ok ] && echo 1 || echo 0)"
chk "⑬a 走的是『和我刚进来时读到的一模一样』那一支(不是名单里那条)"     "$(grep -aq '和我刚进来时读到的一模一样' "$W/log_unkbase.txt" && echo 1 || echo 0)"
chk "⑬a 只打了一串字(实得 $(ncall unkbase '^S|input text'))" "$([ "$(ncall unkbase '^S|input text')" = 1 ] && echo 1 || echo 0)"

echo "=== ⑬b 同一个基准，但第二次打字 ⇒ 必须不再认它(那时残留是我自己打进去的) ==="
RUN_UG='搜超级用户' RUN_BASEOK=0 run rebase termux unkbase unkbase unkbase
chk "⑬b 结果=nclean(第二次起『回到基准』不再算干净)" "$([ "$(out rebase)" = nclean ] && echo 1 || echo 0)"
chk "⑬b 这一格一条字都没打(实得 $(ncall rebase '^S|input text'))＝正对照是 ⑬a 那条 1"     "$([ "$(ncall rebase '^S|input text')" = 0 ] && echo 1 || echo 0)"

# ---------- #169：打字之前的"输入法能不能直接提交"探针 ----------
prun() {   # 照出货件那条调用走：ime_probe 不过 ⇒ 一条真字都不许打
  local name=$1; shift
  : > "$W/log_$name.txt"; : > "$W/calls_$name.log"; echo 0 > "$W/n_$name"
  : > "$W/seq_$name"; local f; for f in "$@"; do echo "$W/fix/$f.xml" >> "$W/seq_$name"; done
  (
    cd "$W" || exit 1
    EV="$W/ev"; PY=python; TERM='termux'; WORD='termux'; WANT_PKG=com.termux; FIELD_LAST=""
    UGBASE=""; BASE_OK=1
    S()   { printf 'S|%s
' "$1" >> "$W/calls_$name.log"; return 0; }
    adb() { printf 'A|%s
' "$*" >> "$W/calls_$name.log"; return 0; }
    sleep() { :; }
    dump_to() {
      local i n f
      i=$(($(cat "$W/n_$name") + 1)); echo $i > "$W/n_$name"
      n=$(grep -ac . "$W/seq_$name"); f=$(sed -n "${i}p" "$W/seq_$name")
      [ -n "$f" ] || f=$(tail -1 "$W/seq_$name")
      cp "$f" "$1"
    }
    source "$W/legs.sh"
    if ime_probe; then
      if prove_empty && type_term_once; then echo "OUT=ok"; else echo "OUT=retry"; fi
    else
      echo "OUT=nosubmit"
    fi
    echo "DUMPS=$(cat "$W/n_$name")"
  ) > "$W/log_$name.txt" 2>&1
}
echo "=== ⑭ 探针#1：宿主能直接提交(q 逐字回来) ⇒ 放行，且探针那个字符必须清回空 ==="
prun pgood q q empty empty ok
chk "⑭ 探针过之后正常走完一轮：结果=ok(实得 [$(out pgood)])" "$([ "$(out pgood)" = ok ] && echo 1 || echo 0)"
chk "⑭ 探针只打了 1 次 q(实得 $(ncall pgood 'input text ..q'))" "$(grep -aqF 'input text "q"' "$W/calls_pgood.log" && echo 1 || echo 0)"
chk "⑭ 探针收尾把字段清回空(日志里有『已清回空』)" "$(grep -aqF '已清回空' "$W/log_pgood.txt" && echo 1 || echo 0)"
echo "=== ⑭ 探针#2：中文组合态＝打 q 一个字符都不提交 ⇒ 判「仪器测不了」并**零打字** ==="
prun pempty empty empty empty
chk "⑭ 结果=nosubmit(实得 [$(out pempty)])" "$([ "$(out pempty)" = nosubmit ] && echo 1 || echo 0)"
chk "⑭ 这一格 input text termux 次数=0(实得 $(grep -acF 'input text "termux"' "$W/calls_pempty.log" | tr -dc '0-9'))＝★反夹具：探针若被改成「永远放行」，这一格会变 1 而报红"     "$([ "$(grep -acF 'input text "termux"' "$W/calls_pempty.log" | tr -dc '0-9')" = 0 ] && echo 1 || echo 0)"
chk "⑭ 消息点名成因＝字母进了合成区(而不是含糊的「打不对」)" "$(grep -aqF '拼音' "$W/log_pempty.txt" && echo 1 || echo 0)"
echo "=== ⑭ 探针#3：全角形状(点被换成句号)⇒ 同样判「测不了」，并把实得读数打出来 ==="
prun pfw fw empty empty
chk "⑭ 结果=nosubmit(实得 [$(out pfw)])" "$([ "$(out pfw)" = nosubmit ] && echo 1 || echo 0)"
chk "⑭ 说了是「输入法在做转换」这一类" "$(grep -aqF '输入法在做转换' "$W/log_pfw.txt" && echo 1 || echo 0)"
chk "⑭ 把实得的那个全角字符印进日志(读数要能复核，不能只剩结论)" "$(grep -aqF '。' "$W/log_pfw.txt" && echo 1 || echo 0)"
echo "=== ⑭ 探针#4：出货件里这条腿必须有生产者(例 116：格定义里的词没人实现＝静悄悄换形状) ==="
chk "⑭ 调用点存在：ime_probe 不过就 exit 9" "$(grep -aqF 'ime_probe || exit 9' kmod/ui_grant.sh && echo 1 || echo 0)"
chk "⑭ 只测一次：靠 IME_OK 记住宿主状态(别每轮花两次 dump 问同一件事)" "$(grep -aqF 'IME_OK:-0' kmod/ui_grant.sh && echo 1 || echo 0)"
chk "⑭ 退出码 9 在头注里有定义(交付文档要能解释它，不能只存在于代码里)" "$(grep -aqF '9＝输入法不可直接提交' kmod/ui_grant.sh && echo 1 || echo 0)"

echo "=== ⑬ 切片里不许有反引号执行(例 76：出货件自己在 echo 里执行反引号) ==="
chk "⑬legs.sh 里带反引号的行全是注释" \
    "$(awk '/`/ { if ($0 !~ /^[[:space:]]*#/) bad=1 } END { exit bad?1:0 }' "$W/legs.sh" && echo 1 || echo 0)"

echo
if [ "$fail" = 0 ]; then echo "=== w458 全绿：$nchk 项 PASS(条数由本脚本自己现数)"; exit 0; fi
echo "=== w458 有红项：$nchk 项里含 [BAD] ==="; exit 1
