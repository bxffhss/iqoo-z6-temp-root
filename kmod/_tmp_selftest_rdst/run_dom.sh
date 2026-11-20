#!/usr/bin/env bash
# run_dom.sh —— #117 那格的形状词「名单记录的域=X」的生产者双向自测(不碰设备、不开窗)。
#   被测三处：①kmod/ksu_one_stage.sh 里 `DOMF=`…`DOM=${DOMF:-…}` 那两行
#             ②同文件的「★DOM 生效证人」那行(两支都要打得出来)
#             ③kmod/go.sh 的 1.68 段(校验→铺文件→读回；不给→rm -f 并复证)
#   ★切片边界要有牙：切出来必须含被测行本身、不许把邻居段吞进来、锚不许只在注释里。
#   ★夹具与真机同源：设备绝对路径用 sed 换成 $W/dev/ 下的真文件，换完必须"旧路径零残留"，
#     否则以后谁改了路径这套就在测空气(例 88/127)。
set -u
cd "$(dirname "$0")/../.." || exit 1
W=$(mktemp -d)
DEV=$W/dev
mkdir -p "$DEV"
SW=$DEV/ksu_dom
nchk=0; fail=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

# ---------- 切片 1：stage 读开关那几行(§6.353 起含 dom_for) ----------
#   终点打在 stage 里那行"==== DOM 段结束 ===="的标记上——**这段整体是"没有开关文件 ⇒ 逐字等于老行为"**，
#   自测要测的就是这一整段，所以标记由 stage 自己写着，漂移了就是这里先红。
awk 'index($0,"DOMF=$(head -1 /data/local/tmp/ksu_dom"){f=1} f{print} index($0,"==== DOM 段结束"){f=0}' \
    kmod/ksu_one_stage.sh | sed "s|/data/local/tmp|$DEV|g" > "$W/stage_dom.sh"
grep -qF 'DOMF=$(head -1' "$W/stage_dom.sh" || { echo "[x] 没切到 stage 的 DOM 读取(起点锚失效)"; exit 1; }
grep -qF 'DOM=${DOMF:-' "$W/stage_dom.sh" || { echo "[x] 切出来不含 DOM 赋值那行(终点锚失效)"; exit 1; }
grep -qF 'dom_for()' "$W/stage_dom.sh" || { echo "[x] 切出来不含 dom_for ⇒ §6.353 那段没进来(证人会跑不动)"; exit 1; }
[ "$(grep -c '/data/local/tmp' "$W/stage_dom.sh")" = 0 ] || { echo "[x] 夹具路径没替换干净 ⇒ 格子会写设备绝对路径"; exit 1; }
[ "$(grep -c 'ksu_ap_key' "$W/stage_dom.sh")" = 0 ] || { echo "[x] 切片把 AP_KEY 那几行也吞进来了(终点锚失效)"; exit 1; }
[ "$(grep -c 'WAIT_LOOPS' "$W/stage_dom.sh")" = 0 ] || { echo "[x] 切片吞过了头(把后面的变量段也捞进来了)"; exit 1; }

# ---------- 切片 2：stage 的生效证人那行 ----------
#   ★锚必须打在 `log "` 上：光搜「★DOM 生效证人」会把上面那段说明注释也捞进来(第一版就是这么红的)。
grep -a '^log "  ★DOM 生效证人' kmod/ksu_one_stage.sh | sed "s|/data/local/tmp|$DEV|g" > "$W/stage_witness.sh"
[ "$(wc -l < "$W/stage_witness.sh")" = 1 ] || { echo "[x] 生效证人切出来不是恰好 1 行(被复制了或锚漂了)"; exit 1; }
[ "$(grep -c '/data/local/tmp' "$W/stage_witness.sh")" = 0 ] || { echo "[x] 证人行的夹具路径没替换干净"; exit 1; }

# ---------- 切片 3：go.sh 的 1.68 段（★终点是 1.68b，不是 1.7——1.69/1.68b 各有自己的自测） ----------
awk 'index($0,"=== 1.68)"){f=1} index($0,"=== 1.68b)"){f=0} f' kmod/go.sh > "$W/go_block.sh"
grep -qF '=== 1.68)' "$W/go_block.sh" || { echo "[x] 没切到 go.sh 的 1.68 段(起点锚失效)"; exit 1; }
grep -qF '官方 Manager 要能用' "$W/go_block.sh" && { echo "[x] 切片一路吞到 1.7 了(终点锚失效)"; exit 1; }
grep -qF 'DOM_MAP' "$W/go_block.sh" && { echo "[x] 切片把 1.68b(DOM_MAP)也吞进来了 ⇒ 那段的自测在 run_dommap.sh"; exit 1; }
grep -qF '*[!-A-Za-z0-9._,:]*' "$W/go_block.sh" || { echo "[x] 切片里没有那条字符白名单 ⇒ 起点锚对但校验不在"; exit 1; }
echo "切片行数：stage_dom=$(wc -l < "$W/stage_dom.sh")  witness=$(wc -l < "$W/stage_witness.sh")  go_block=$(wc -l < "$W/go_block.sh")"

run_stage() { # $1=tag $2=开关文件内容(不传=不建文件；可用 \r\n 转义) $3=env 里的 DOM(空=不设)
    rm -f "$SW"
    if [ "$#" -ge 2 ]; then printf '%b' "$2" > "$SW"; fi
    ( cd "$W" || exit 1
      PKG=com.suw.manager
      if [ -n "${3:-}" ]; then export DOM="$3"; else unset DOM; fi
      . "$W/stage_dom.sh"
      echo "RESULT_DOM=[$DOM]"
    ) > "$W/out_$1.txt" 2>&1
    echo "----- stage case $1(文件=$([ -f "$SW" ] && echo 在 || echo 不在) 内容b='${2:-}' env='${3:-}') -----"
    sed 's/^/    /' "$W/out_$1.txt"
}
run_witness() { # 紧接 run_stage 之后跑，复用同一次的文件/env 状态
    ( cd "$W" || exit 1
      if [ -n "${2:-}" ]; then export DOM="$2"; else unset DOM; fi
      SUWID=10342
      log() { echo "$*"; }
      # ★先跑真的赋值切片，再跑证人切片——**不在这里重算一遍 DOM**(那是"我算的等于它算的"假闸)
      . "$W/stage_dom.sh"
      . "$W/stage_witness.sh"
    ) > "$W/out_$1.txt" 2>&1
    echo "----- witness case $1 -----"
    sed 's/^/    /' "$W/out_$1.txt"
}
go_rc() { # $1=tag $2=给 DOM 的值(空=不给) $3=事先铺的残留内容(空=不建)；打印 rc，输出留在 out_tag.txt
    rm -f "$SW"
    [ -n "${3:-}" ] && printf '%s' "$3" > "$SW"
    ( cd "$W" || exit 1
      A() { eval "${1//\/data\/local\/tmp/$DEV}"; }
      if [ -n "${2:-}" ]; then export DOM="$2"; else unset DOM; fi
      . "$W/go_block.sh"
    ) > "$W/out_$1.txt" 2>&1
    echo $?
}

DEF='u:r:shell:s0'
APPDOM='u:r:untrusted_app_25:s0:c512,c768'

echo "=== 一) stage 读开关：默认／覆盖／空文件／CRLF／env 优先级 ==="
run_stage s_nofile
chk "①没开关文件：必须逐字保持交付默认($DEF)" "$(grep -qaxF "RESULT_DOM=[$DEF]" "$W/out_s_nofile.txt" && echo 1 || echo 0)"
run_stage s_appdom "$APPDOM"
chk "②开关=$APPDOM：必须整串覆盖(拿我现算的期望值去 grep 整行)" "$(grep -qaxF "RESULT_DOM=[$APPDOM]" "$W/out_s_appdom.txt" && echo 1 || echo 0)"
run_stage s_empty ""
chk "③开关文件存在但 0 字节：必须退回默认(半截开关不许造出空域)" "$(grep -qaxF "RESULT_DOM=[$DEF]" "$W/out_s_empty.txt" && echo 1 || echo 0)"
run_stage s_crlf "${APPDOM}\\r\\n"
chk "④开关内容带 CRLF：tr 必须剥干净，值要逐字等于裸串" "$(grep -qaxF "RESULT_DOM=[$APPDOM]" "$W/out_s_crlf.txt" && echo 1 || echo 0)"
run_stage s_env "$APPDOM" 'u:r:kernel:s0'
chk "⑤文件与 env 同时给：文件必须赢(优先级有定稿)" "$(grep -qaxF "RESULT_DOM=[$APPDOM]" "$W/out_s_env.txt" && echo 1 || echo 0)"
run_stage s_envonly "" 'u:r:kernel:s0'
chk "⑥只有 env(老写法)：仍要生效 ⇒ 默认值不许把它吃掉" "$(grep -qaxF "RESULT_DOM=[u:r:kernel:s0]" "$W/out_s_envonly.txt" && echo 1 || echo 0)"

echo "=== 二) stage 的生效证人那行：两支都要打得出来 ==="
rm -f "$SW"; run_witness w_nofile
chk "⑦没开关文件：证人要明打『不在⇒用默认 u:r:shell:s0』" "$(grep -aqF '不在⇒用默认 u:r:shell:s0' "$W/out_w_nofile.txt" && echo 1 || echo 0)"
chk "⑦没开关文件：主条目 uid=10342 域=[$DEF]" "$(grep -aqF "主条目 uid=10342 域=[$DEF]" "$W/out_w_nofile.txt" && echo 1 || echo 0)"
chk "⑦没映射文件：证人要明打『不在⇒每条都用上面那个全局 DOM』(§6.353 那一支的存在性也要留痕)" "$(grep -aqF '不在⇒每条都用上面那个全局 DOM' "$W/out_w_nofile.txt" && echo 1 || echo 0)"
printf '%s' "$APPDOM" > "$SW"; run_witness w_file
chk "⑧铺了开关：证人要打出实际值(不许仍写『不在⇒用默认』)" "$(grep -aqF "主条目 uid=10342 域=[$APPDOM]" "$W/out_w_file.txt" && ! grep -aqF '不在⇒用默认' "$W/out_w_file.txt" && echo 1 || echo 0)"
chk "⑧铺了开关：证人要把开关文件的路径带出来(入口证人要说清来源)" "$(grep -aqF "$SW" "$W/out_w_file.txt" && echo 1 || echo 0)"

echo "=== 三) go.sh 的 1.68 段：铺／校验／不给时的清理 ==="
rm -f "$SW"
RC=$(go_rc g_ok "$APPDOM")
chk "⑨给合法 DOM：rc 要 0(实得 rc=$RC)" "$([ "$RC" = 0 ] && echo 1 || echo 0)"
chk "⑨给合法 DOM：开关文件真被铺上且逐字等于输入(第一遍真的改了，例 88)" "$([ -f "$SW" ] && [ "$(cat "$SW" 2>/dev/null)" = "$APPDOM" ] && echo 1 || echo 0)"
chk "⑨给合法 DOM：读回那行的值＝我算的输入(不许它自己复述)" "$(grep -aqF "开关内容读回=[$APPDOM]" "$W/out_g_ok.txt" && echo 1 || echo 0)"
chk "⑨给合法 DOM：这一段不许冒出工具自己的报错(sed/awk/bash 自己坏了也要红)" "$(! grep -aqE "sed: |grep: |awk: |bash: " "$W/out_g_ok.txt" && echo 1 || echo 0)"
rm -f "$SW"
RC=$(go_rc g_inject 'u:r:shell:s0;rm -rf /')
chk "⑩含分号的注入串：必须 rc=3 硬停(实得 rc=$RC)" "$([ "$RC" = 3 ] && echo 1 || echo 0)"
chk "⑩含分号的注入串：一条都不许铺(文件不在)" "$([ ! -e "$SW" ] && echo 1 || echo 0)"
chk "⑩含分号的注入串：打的是『含非法字符』那条支，不是别的" "$(grep -aqF '含非法字符' "$W/out_g_inject.txt" && echo 1 || echo 0)"
RC=$(go_rc g_prefix 'r:shell:s0')
chk "⑪不带 u: 前缀：rc=3 且明说形状不对(实得 rc=$RC)" "$([ "$RC" = 3 ] && grep -aqF '必须以 u: 开头' "$W/out_g_prefix.txt" && echo 1 || echo 0)"
LONG=$(printf 'u:r:%s:s0' "$(printf 'a%.0s' $(seq 1 90))")
RC=$(go_rc g_long "$LONG")
chk "⑫超长：rc=3(实得 rc=$RC 长度=${#LONG})" "$([ "$RC" = 3 ] && grep -aqF 'DOM 长度' "$W/out_g_long.txt" && echo 1 || echo 0)"
RC=$(go_rc g_off '' "$APPDOM")
chk "⑬不给 DOM：rc 要 0(实得 rc=$RC)" "$([ "$RC" = 0 ] && echo 1 || echo 0)"
chk "⑬不给 DOM：上一发的残留开关必须被删掉且有复证行" "$([ ! -e "$SW" ] && grep -aqF 'No such file' "$W/out_g_off.txt" && echo 1 || echo 0)"
chk "⑬不给 DOM：明打本格＝交付形状" "$(grep -aqF '交付形状(域=u:r:shell:s0)' "$W/out_g_off.txt" && echo 1 || echo 0)"

rm -rf "$W"
echo
[ "$fail" = 0 ] && echo "=== run_dom 自测 PASS(共 $nchk 项断言，条数由 chk 自数) ===" || echo "=== FAIL($nchk 项里有红) ==="
[ "$fail" = 0 ]
