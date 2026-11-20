#!/usr/bin/env bash
# run_rowpick.sh —— 第 35 发那两道 UI 闸的离线双向自测(0 枪)：
#   kmod/row_pick.py v2(找**可点的卡**，不是找文本行) ＋ kmod/prof_gate.py(身份闸从「包名∧UID」改成「App Profile∧UID」)。
# ★夹具全部来自**真机一手树的冻结副本**(不是手搓的漂亮形状)：
#     w462_srctree.xml＝第 35 发过滤后的列表页(=当时的 ug_srch.xml)
#     w462_prof.xml   ＝手工点中卡后进的那一页 Profile(开关 checked=false，点它之前)
#     w462_prof2.xml  ＝同一页点过之后(checked=true)⇒ 证明 checked 那条读数跟着状态走，不是常量
#   ★为什么必须另起名字冻结：`ug_srch.xml`/`ug_prof.xml` 是 ui_grant.sh 自己每一跑都覆盖的落点
#     (例 110 那一族：夹具被它所认证的那条腿写花)。第 ⓪格就是这条的守卫。
set -u
cd "$(dirname "$0")"/"../.." || exit 1
# ★GBK 控制台遇到 '⇒' 会把 python 的 print 打崩(第 110 发真崩过，出货件 ui_grant.sh:42 也export了它)：
#   这一格的红长得像"工具坏了"，其实是本机编码 ⇒ 两件 py 都靠 print 出读数，必须在这里垫同源的环境变量。
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
# ★三件被测都能被变异驱动(_mut_rowpick.sh)换成临时副本：变异打在副本上跑，绝不动出货件。
EV=kmod/w103_evidence
RP=${RP:-kmod/row_pick.py}
PG=${PG:-kmod/prof_gate.py}
UG=${UG:-kmod/ui_grant.sh}
W=$(mktemp -d)
nchk=0; fail=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }
rp() { # $1=xml $2=want $3=out $4=term(可空) —— rc 必须**直接**取，不能过管道(例 103)
  python "$RP" "$1" "$2" "$3" ${4:+"$4"} > "$W/rp.out" 2>&1; RP_RC=$?
  return 0
}
pg() { # $1=xml $2=want $3=uid $4=out
  python "$PG" "$1" "$2" "$3" "$4" > "$W/pg.out" 2>&1; PG_RC=$?
  return 0
}
# ①那一格的"独立复核"探针(单独写进临时件再调用：heredoc 塞进命令替换是这台机上会炸的形状)：
# 命中点必须落在某个 clickable="true" 节点的 bounds 里——它**不读** row_pick 的文案，只量树。
cat > "$W/inclk.py" <<'PY'
import io,re,sys
p,x,y=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
s=io.open(p,encoding='utf-8',errors='replace').read()
ok=False
for m in re.finditer(r'<node[^>]*',s):
    t=m.group(0)
    if 'clickable="true"' not in t:
        continue
    b=re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',t)
    if not b:
        continue
    g=[int(v) for v in b.groups()]
    if g[0]<=x<=g[2] and g[1]<=y<=g[3]:
        ok=True
sys.exit(0 if ok else 1)
PY

echo "=== ⓪ 夹具：三份真树必须在、非 0 字节、且不是被出货件覆盖的那两个名字 ==="
for f in w462_srctree.xml w462_prof.xml w462_prof2.xml; do
    chk "⓪夹具 $f 存在且非 0 字节(实得 $(wc -c < "$EV/$f" 2>/dev/null || echo 无) B)" \
        "$([ -s "$EV/$f" ] && echo 1 || echo 0)"
done
chk "⓪出货件的**非注释行**里不出现 w462_ ⇒ 它只覆盖 ug_*.xml，动不到夹具(例 110；注释里引用出处允许)" \
    "$(grep -av '^[[:space:]]*#' "$UG" | grep -qa 'w462_' && echo 0 || echo 1)"
chk "⓪一手事实复核：真 Profile 树里 com.termux 出现 0 次(实得 $(grep -aoc 'com\.termux' "$EV/w462_prof.xml" | tr -dc '0-9'))" \
    "$(grep -aoc 'com\.termux' "$EV/w462_prof.xml" | grep -qx 0 && echo 1 || echo 0)"

echo "=== ① 真树＋com.termux：必须命中唯一那张**可点卡**，坐标要能被独立复核 ==="
rp "$EV/w462_srctree.xml" com.termux "$W/row.txt"
chk "①rc=0(实得 $RP_RC；读数见 $W/rp.out)" "$([ "$RP_RC" = 0 ] && echo 1 || echo 0)"
XY=$(tr -d '\r\n' < "$W/row.txt" 2>/dev/null)
chk "①写出的坐标是整数对(实得 [$XY])" "$(printf '%s' "$XY" | grep -qxE '[0-9]+ [0-9]+' && echo 1 || echo 0)"
chk "①坐标＝(540,414)＝第 35 发手工点中并进到 Profile 页的那个点" "$([ "$XY" = '540 414' ] && echo 1 || echo 0)"
chk "①**独立复核**：那个点确实落在某个 clickable=true 节点的 bounds 里(不是我读它的文案)" \
    "$(python "$W/inclk.py" "$EV/w462_srctree.xml" $XY >/dev/null 2>&1; [ $? = 0 ] && echo 1 || echo 0)"
chk "①回归：v2 不再给 v1 那个不可点的文本行中心(383,849)" "$([ "$XY" != '383 849' ] && echo 1 || echo 0)"
chk "①整屏滚动容器 [0,0][1080,2388] 没被当成卡(它包住另一张卡⇒不是最小)" \
    "$(grep -qa '可点卡片 1 张' "$W/rp.out" && ! grep -qa '\[0,0\]\[1080,2388\]' "$W/rp.out" && echo 1 || echo 0)"

echo '=== ② 显式给过滤词(出货件走的就是这一支：ui_grant 把它的 TERM 变量当第 4 个参数传进来) ==='
rp "$EV/w462_srctree.xml" com.termux "$W/row2.txt" termux
chk "②rc=0(实得 $RP_RC)" "$([ "$RP_RC" = 0 ] && echo 1 || echo 0)"
chk "②与①逐字同一坐标(推导词与现取词不许给出两个答案)" "$([ "$(tr -d '\r\n' < "$W/row2.txt")" = "$XY" ] && echo 1 || echo 0)"

echo "=== ③ 负半边：没授权的包必须拒点，而且**必须删掉残留坐标** ==="
printf '111 222' > "$W/row3.txt"          # ★先铺一颗地雷：拒点时如果没删，下一轮 read 就把它点了
rp "$EV/w462_srctree.xml" com.tencent.baiye "$W/row3.txt"
chk "③rc=3(卡里没有 baiye；实得 $RP_RC)" "$([ "$RP_RC" = 3 ] && echo 1 || echo 0)"
chk "③拒点后输出文件**不存在**(那颗铺好的 111 222 必须被删)" "$([ ! -f "$W/row3.txt" ] && echo 1 || echo 0)"

echo "=== ④ 没有卡 / 多张卡：两种拒点各有各的码，不许都读成『没找到』 ==="
printf '%s\n' '<hierarchy>' \
 '<node text="搜索" class="android.widget.EditText" clickable="true" bounds="[36,143][874,287]"/>' \
 '</hierarchy>' > "$W/nocard.xml"
rp "$W/nocard.xml" com.termux "$W/row4.txt" termux
chk "④树里没有可点卡 ⇒ rc=4(实得 $RP_RC)" "$([ "$RP_RC" = 4 ] && echo 1 || echo 0)"
printf '%s\n' '<hierarchy>' \
 '<node class="android.view.View" clickable="true" bounds="[36,318][1044,510]"/>' \
 '<node text="Termux user" class="android.widget.TextView" bounds="[240,358][572,424]"/>' \
 '<node text="包含 35 个应用" class="android.widget.TextView" bounds="[240,424][510,471]"/>' \
 '<node class="android.view.View" clickable="true" bounds="[36,520][1044,712]"/>' \
 '<node text="Termux 另一个" class="android.widget.TextView" bounds="[240,560][572,626]"/>' \
 '<node text="com.termux" class="android.widget.TextView" bounds="[240,626][510,673]"/>' \
 '</hierarchy>' > "$W/twocards.xml"
rp "$W/twocards.xml" com.termux "$W/row5.txt" termux
chk "④两张卡都含 termux ⇒ 有歧义必须 rc=5(实得 $RP_RC)" "$([ "$RP_RC" = 5 ] && echo 1 || echo 0)"
rp "$W/没有这个文件.xml" com.termux "$W/row6.txt" termux
chk "④树文件不存在 ⇒ rc=4 并明说『不存在或 0 字节』(缺文件不许读成页面是空的)" \
    "$([ "$RP_RC" = 4 ] && grep -qa '不存在或 0 字节' "$W/rp.out" && echo 1 || echo 0)"
printf '55 66' > "$W/row7.txt"
rp "$W/没有这个文件.xml" com.termux "$W/row7.txt" termux
chk "④坏树那一支也要删残留(铺好的 55 66 必须没了)" "$([ ! -f "$W/row7.txt" ] && echo 1 || echo 0)"

echo "=== ⑤ Profile 身份闸：真页必须过，且过的那一半是 UID 不是包名 ==="
pg "$EV/w462_prof.xml" com.termux 10667 "$W/pg1.txt"
chk "⑤真 Profile 树＋对的 uid ⇒ rc=0(实得 $PG_RC)" "$([ "$PG_RC" = 0 ] && echo 1 || echo 0)"
OUT1=$(tr -d '\r\n' < "$W/pg1.txt" 2>/dev/null)
chk "⑤写出四个字段(实得 [$OUT1])" "$(printf '%s' "$OUT1" | grep -qxE '[0-9]+ [0-9]+ (true|false) 1' && echo 1 || echo 0)"
chk "⑤开关中心＝(922,802)、checked=false(＝点它之前的状态，真树现量)" "$([ "$OUT1" = '922 802 false 1' ] && echo 1 || echo 0)"
chk "⑤包名那条判的是『不中(只当读数)』——承重不能偷偷还是包名" "$(grep -qa '只当读数' "$W/pg.out" && echo 1 || echo 0)"
chk "⑤读数里印出这一页自己的代表包 com.galMag.dataViewer(驼峰也要认得)" "$(grep -qa 'com.galMag.dataViewer' "$W/pg.out" && echo 1 || echo 0)"
chk "⑤**旧闸会判负**的同源复核：这一页里 UID 10667 有、com.termux 没有 ⇒ 修法是真改了结果不是化妆" \
    "$(grep -qa 'UID 10667' "$W/pg.out" && [ "$(grep -aoc 'com\.termux' "$EV/w462_prof.xml" | tr -dc '0-9')" = 0 ] && echo 1 || echo 0)"

echo "=== ⑥ checked 那条读数跟着状态走(不是常量) ==="
pg "$EV/w462_prof2.xml" com.termux 10667 "$W/pg2.txt"
chk "⑥点过之后那份树 ⇒ rc=0(实得 $PG_RC)" "$([ "$PG_RC" = 0 ] && echo 1 || echo 0)"
chk "⑥同一页读数变成 checked=true(实得 [$(tr -d '\r\n' < "$W/pg2.txt")])" "$([ "$(tr -d '\r\n' < "$W/pg2.txt")" = '922 802 true 1' ] && echo 1 || echo 0)"

echo "=== ⑦ 闸门的红支：错 uid / 不是 Profile 页 / 文件缺失，三支都必须拒写 ==="
printf '9 9 true 1' > "$W/pg3.txt"
pg "$EV/w462_prof.xml" com.termux 10999 "$W/pg3.txt"
chk "⑦uid 不符 ⇒ rc=6(实得 $PG_RC)" "$([ "$PG_RC" = 6 ] && echo 1 || echo 0)"
chk "⑦判负时把缺的那半点名(App Profile/UID 哪个没中)" "$(grep -qa '缺的那半' "$W/pg.out" && echo 1 || echo 0)"
chk "⑦拒写并删残留(铺好的 9 9 必须没了)" "$([ ! -f "$W/pg3.txt" ] && echo 1 || echo 0)"
pg "$EV/w462_srctree.xml" com.termux 10667 "$W/pg4.txt"
chk "⑦列表页(没有 checkable 开关)⇒ rc=4(实得 $PG_RC)＝这一页不是 Profile 页" "$([ "$PG_RC" = 4 ] && echo 1 || echo 0)"
pg "$W/也没有这个文件.xml" com.termux 10667 "$W/pg5.txt"
chk "⑦树文件不存在 ⇒ rc=3 且明说『dump 这一腿没成』(不能读成页面空)" \
    "$([ "$PG_RC" = 3 ] && grep -qa 'dump 这一腿根本没成' "$W/pg.out" && echo 1 || echo 0)"

echo "=== ⑧ 静态牙：出货件必须真的调用这两件(否则改的是没人走的代码，例 116/141) ==="
NONCMT=$(grep -av '^[[:space:]]*#' "$UG")
chk "⑧ui_grant.sh 里 row_pick 的调用**带了过滤词那第 4 个参数**" "$(printf '%s' "$NONCMT" | grep -qE 'row_pick\.py .*build_ug_row\.txt +"\$TERM"' && echo 1 || echo 0)"
chk "⑧ui_grant.sh 里在调 kmod/prof_gate.py(身份闸有生产者)" "$(printf '%s' "$NONCMT" | grep -q 'kmod/prof_gate\.py' && echo 1 || echo 0)"
chk "⑧旧的那段内联 python 已经没了(非注释行里 checkable 字样 0 次，实得 $(printf '%s' "$NONCMT" | grep -ac 'checkable=\"true\"' | tr -dc '0-9'))" \
    "$(printf '%s' "$NONCMT" | grep -qa 'checkable="true"' && echo 0 || echo 1)"
chk "⑧两个 py 都能过 py_compile(语法闸)" "$(python -m py_compile "$RP" "$PG" >/dev/null 2>&1 && echo 1 || echo 0)"
chk "⑧prof_gate.py 的包名形状正则容大写(真代表包是驼峰 com.galMag.dataViewer)" \
    "$(grep -A1 '^PKGSHAPE = ' "$PG" | grep -qa 'A-Z' && echo 1 || echo 0)"

rm -rf "$W"
echo
[ "$fail" = 0 ] && echo "=== run_rowpick 自测 PASS(共 $nchk 项断言，条数由 chk 自数) ===" || echo "=== FAIL($nchk 项里有红) ==="
[ "$fail" = 0 ]
