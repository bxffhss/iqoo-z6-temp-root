#!/usr/bin/env bash
# run_dommap.sh —— §6.353 那把「每条名单记录各自的域」(`DOM_MAP`)的双向离线自测(不碰设备、不开窗)。
#   被测两段(都是从出货文件里按"两头有牙"的锚切片，锚漂了 exit 1 而不是静默空跑)：
#     ①stage 的 DOM 段(DOMF/DOM/DOMMAP/dom_for) ⇒ 直接打 `dom_for <uid>` 看解析结果
#     ②go.sh 的 §1.68b(DOM_MAP 校验→铺→读回；不给⇒rm 并复证)
#   ★为什么值得单独一件：`DOM` 一整窗一个值，第 26 发之后剩下的形状差就在"每条各自的域"上，
#     而这张表如果哪天被读错(前缀撞车／uid 非数字／串里带空格)，症状会是"某个 app 静悄悄换了域"。
set -u
cd "$(dirname "$0")/../.." || exit 1
W=$(mktemp -d); DEV=$W/dev; mkdir -p "$DEV"
SW=$DEV/ksu_dom; SM=$DEV/ksu_dom_map
nchk=0; fail=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

# ---------- 切片 1：stage 的 DOM 段 ----------
awk 'index($0,"DOMF=$(head -1 /data/local/tmp/ksu_dom"){f=1} f{print} index($0,"==== DOM 段结束"){f=0}' \
    kmod/ksu_one_stage.sh | sed "s|/data/local/tmp|$DEV|g" > "$W/stage_dom.sh"
grep -qF 'dom_for()' "$W/stage_dom.sh" || { echo "[x] 没切到 dom_for(锚漂了或 stage 里那段被改名)"; exit 1; }
grep -qF 'DOMMAP='"$DEV"'/ksu_dom_map' "$W/stage_dom.sh" || { echo "[x] 切片里的映射路径没被换成夹具路径"; exit 1; }
[ "$(grep -c '/data/local/tmp' "$W/stage_dom.sh")" = 0 ] || { echo "[x] 夹具路径没替换干净"; exit 1; }
[ "$(grep -c 'WAIT_LOOPS' "$W/stage_dom.sh")" = 0 ] || { echo "[x] 切片吞过了头"; exit 1; }

# ---------- 切片 2：go.sh 的 1.68b 段 ----------
awk 'index($0,"=== 1.68b)"){f=1} index($0,"=== 1.69)"){f=0} f' kmod/go.sh > "$W/map_block.sh"
grep -qF '=== 1.68b)' "$W/map_block.sh" || { echo "[x] 没切到 1.68b(起点锚失效)"; exit 1; }
grep -qF '官方 Manager 要能用' "$W/map_block.sh" && { echo "[x] 一路吞到 1.7 了(终点锚失效)"; exit 1; }
grep -qF 'rm -f /data/local/tmp/ksu_dom_map' "$W/map_block.sh" || { echo "[x] 切片里没有「不给时清映射」那半"; exit 1; }
grep -qF "tr -d -- '-A-Za-z0-9._,:;='" "$W/map_block.sh" || { echo "[x] 切片里没有那条非法字符检查(case 里放不进分号，见 go.sh 注释)"; exit 1; }
# ★反引号在 echo 的双引号里会**真的执行**(例 76)——第 27 发它就把"生效证人"那行文案吃掉半句、
#   并在转录里留下一行 `profile:: command not found`。注释行里的反引号无害，所以只查非注释行。
[ "$(grep -v '^[[:space:]]*#' "$W/map_block.sh" | grep -c '`')" = 0 ] || { echo "[x] go.sh §1.68b 的**可执行行**里有反引号 ⇒ echo 里会被当命令执行(例 76)"; exit 1; }
sed "s|/data/local/tmp|$DEV|g" "$W/map_block.sh" > "$W/map_run.sh"
echo "切片行数：stage_dom=$(wc -l < "$W/stage_dom.sh")  map_block=$(wc -l < "$W/map_block.sh")"

DEF='u:r:shell:s0'
A_DOM='u:r:untrusted_app:s0:c86,c257,c512,c768'
B_DOM='u:r:untrusted_app_25:s0:c512,c768'

# ---------- 一) stage 的 dom_for ----------
run_for() { # $1=tag $2=映射文件内容(不传=不建) $3=开关文件 ksu_dom 的内容(不传=不建) $4=查的 uid
    rm -f "$SM" "$SW"
    [ "$#" -ge 3 ] && [ -n "${3:-}" ] && printf '%s' "$3" > "$SW"
    [ "$#" -ge 2 ] && printf '%b' "$2" > "$SM"
    ( cd "$W" || exit 1
      SUWID=10342
      . "$W/stage_dom.sh"
      echo "DOM_FOR_$4=[$(dom_for "$4")]"
      echo "GLOBAL_DOM=[$DOM]"
    ) > "$W/out_$1.txt" 2>&1
    echo "----- dom_for case $1(映射='${2:-无}' ksu_dom='${3:-无}' 查 uid=$4) -----"
    sed 's/^/    /' "$W/out_$1.txt"
}
echo "=== 一) stage 的 dom_for：没有映射⇒逐字等于全局 DOM；有映射⇒按 uid 命中 ==="
run_for f_nomap "" "" 10342
chk "①没有映射文件：dom_for(10342) 必须逐字＝$DEF(交付形状不许被动)" "$(grep -qaxF "DOM_FOR_10342=[$DEF]" "$W/out_f_nomap.txt" && echo 1 || echo 0)"
run_for f_hit "10342 $A_DOM
" "" 10342
chk "②映射里有这一行：dom_for(10342)＝我现算的 $A_DOM" "$(grep -qaxF "DOM_FOR_10342=[$A_DOM]" "$W/out_f_hit.txt" && echo 1 || echo 0)"
run_for f_miss "10342 $A_DOM
" "" 9999
chk "③映射里没有那个 uid：必须退回全局 DOM(不许拿别人的域)" "$(grep -qaxF "DOM_FOR_9999=[$DEF]" "$W/out_f_miss.txt" && echo 1 || echo 0)"
run_for f_prefix "103420 $B_DOM
" "" 10342
chk "④前缀撞车(103420 那一行)：dom_for(10342) 必须是默认而不是 $B_DOM" "$(grep -qaxF "DOM_FOR_10342=[$DEF]" "$W/out_f_prefix.txt" && echo 1 || echo 0)"
run_for f_mid "9999 10342 u:r:notme:s0
" "" 10342
chk "④b 行里只有行中出现 [10342 空格]（整行是坏格式）：不许命中 ⇒ 这一格才是行首锚的牙(变异 A 打在这)" "$(grep -qaxF "DOM_FOR_10342=[$DEF]" "$W/out_f_mid.txt" && echo 1 || echo 0)"
run_for f_bad "abc $A_DOM
" "" 10342
chk "⑤映射行首字段不是数字：这条不许命中(退回默认)" "$(grep -qaxF "DOM_FOR_10342=[$DEF]" "$W/out_f_bad.txt" && echo 1 || echo 0)"
run_for f_crlf "10342 $A_DOM\\r\\n" "" 10342
chk "⑥映射行带 CRLF：最终取到的值必须是干净串(★这条只证『结果干净』，不证是哪一层剥的——把 dom_for 里的 tr 去掉它照样绿，实测命令替换已经把行尾 CR 一起吞了；所以别拿它当 tr 的牙)" "$(grep -qaxF "DOM_FOR_10342=[$A_DOM]" "$W/out_f_crlf.txt" && echo 1 || echo 0)"
run_for f_empty "" "" 10342
chk "⑦映射文件在但是 0 字节：退回默认(半截开关不许造出空域)" "$(grep -qaxF "DOM_FOR_10342=[$DEF]" "$W/out_f_empty.txt" && echo 1 || echo 0)"
run_for f_two "10342 $A_DOM
10667 $B_DOM
" "" 10667
chk "⑧多条映射：查 10667 要拿到它自己那条" "$(grep -qaxF "DOM_FOR_10667=[$B_DOM]" "$W/out_f_two.txt" && echo 1 || echo 0)"

echo "=== 二) go.sh 的 §1.68b：铺／校验／不给时的清理 ==="
map_rc() { # $1=tag $2=DOM_MAP 的值(空=不给) $3=事先铺的残留
    rm -f "$SM"
    [ -n "${3:-}" ] && printf '%s' "$3" > "$SM"
    ( cd "$W" || exit 1
      A() { eval "${1//\/data\/local\/tmp/$DEV}"; }
      if [ -n "${2:-}" ]; then export DOM_MAP="$2"; else unset DOM_MAP; fi
      . "$W/map_run.sh"
    ) > "$W/out_$1.txt" 2>&1
    echo $?
}
EXPECT="$A_DOM"
RC=$(map_rc m_ok "10342=$A_DOM;10667=$B_DOM")
chk "⑨两段都合法：rc 要 0(实得 $RC)" "$([ "$RC" = 0 ] && echo 1 || echo 0)"
chk "⑨两段都合法：设备侧文件逐字＝我现算的两行(uid 空格 串)" "$([ "$(cat "$SM" 2>/dev/null)" = "10342 $A_DOM
10667 $B_DOM" ] && echo 1 || echo 0)"
chk "⑨两段都合法：读回行与本机基准同一段(不许它自己复述)" "$(grep -qF "设备侧读回=[10342 $A_DOM|10667 $B_DOM]" "$W/out_m_ok.txt" && echo 1 || echo 0)"
chk "⑨这一段不许冒出工具自己的报错(sed/tr/base64 自己坏了也要红)" "$(! grep -aqE "sed: |tr: |base64: |grep: |bash: " "$W/out_m_ok.txt" && echo 1 || echo 0)"
RC=$(map_rc m_inj "10342=u:r:a:s0\$(id -u)")
chk "⑩含 \$( ) 的注入串：rc=3(实得 $RC)" "$([ "$RC" = 3 ] && echo 1 || echo 0)"
chk "⑩含注入串：一条都不许铺" "$([ ! -e "$SM" ] && echo 1 || echo 0)"
chk "⑩含注入串：打的是『含非法字符』那条支" "$(grep -qF '含非法字符' "$W/out_m_inj.txt" && echo 1 || echo 0)"
RC=$(map_rc m_noeq "10342u:r:a:s0")
chk "⑪段里没有 =：rc=3 且点名格式(实得 $RC)" "$([ "$RC" = 3 ] && grep -qF '没有 =' "$W/out_m_noeq.txt" && echo 1 || echo 0)"
RC=$(map_rc m_uid "ab=u:r:a:s0")
chk "⑫uid 不是纯数字：rc=3(实得 $RC)" "$([ "$RC" = 3 ] && grep -qF '不是纯数字' "$W/out_m_uid.txt" && echo 1 || echo 0)"
RC=$(map_rc m_ctx "10342=r:a:s0")
chk "⑬域串不以 u: 开头：rc=3(实得 $RC)" "$([ "$RC" = 3 ] && grep -qF '不以 u: 开头' "$W/out_m_ctx.txt" && echo 1 || echo 0)"
LONG="10342=u:r:$(printf 'a%.0s' $(seq 1 90)):s0"
RC=$(map_rc m_long "$LONG")
chk "⑭域串超长：rc=3(实得 $RC 长度=${#LONG})" "$([ "$RC" = 3 ] && grep -qF '域串长度' "$W/out_m_long.txt" && echo 1 || echo 0)"
RC=$(map_rc m_off '' "$A_DOM")
chk "⑮不给 DOM_MAP：rc 要 0(实得 $RC)" "$([ "$RC" = 0 ] && echo 1 || echo 0)"
chk "⑮不给 DOM_MAP：上一发的残留映射必须被删掉且有复证行" "$([ ! -e "$SM" ] && grep -qF 'No such file' "$W/out_m_off.txt" && echo 1 || echo 0)"
chk "⑮不给 DOM_MAP：明打本格＝每条都用全局 DOM" "$(grep -qF '每条记录的域都等于全局 DOM' "$W/out_m_off.txt" && echo 1 || echo 0)"

rm -rf "$W"
echo
[ "$fail" = 0 ] && echo "=== run_dommap 自测 PASS(共 $nchk 项断言，条数由 chk 自数) ===" || echo "=== FAIL($nchk 项里有红) ==="
[ "$fail" = 0 ]
