pick_term() { # 候选=WORD 本身 + WORD/包名按点切开的每一段，各自剥成 [a-z0-9] 后取最长的那个
  local c best=''
  # ★候选**只有按点切开的段**：把整串(com.termux)也当候选会选出 comtermux——比 termux 长，
  #   而带点整串正是这条腿要避开的成因(离线夹具第⑨格抓到的就是它)。
  for c in $(printf '%s %s' "$WANT_PKG" "$WORD" | tr '.' ' '); do
    c=$(printf '%s' "$c" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')
    [ -n "$c" ] || continue
    [ ${#c} -gt ${#best} ] && best=$c
  done
  printf '%s' "$best"
}
is_empty_field() {
  case "$1" in ''|'搜索'|'搜索…'|'Search'|'搜索设置项'|'请输入搜索内容') return 0 ;; *) return 1 ;; esac
}
field_now() {
  dump_to "$EV/ug_srch.xml" >/dev/null 2>&1
  srch_state >/dev/null 2>&1
  tr -d '\r' < build_ug_field.txt 2>/dev/null
}
prove_empty() {
  local j B A CL CY why
  A=""
  for j in 1 2; do
    B=$(field_now)
    if is_empty_field "$B"; then echo "    证空第 $j 轮：[$B] => 空(在认识的占位符名单里)"; return 0; fi
    if [ "$BASE_OK" = 1 ] && [ "$B" = "$UGBASE" ]; then
      echo "    证空第 $j 轮：[$B] => 和我刚进来时读到的一模一样 ⇒ 这一轮第一次打字按'没被我动过'算干净"
      return 0
    fi
    CL=""; CY=""
    read -r CL CY < build_ug_clean.txt 2>/dev/null || true
    if [[ "$CL" =~ ^[0-9]+$ && "$CY" =~ ^[0-9]+$ ]]; then S "input tap $CL $CY" >/dev/null 2>&1; sleep 1; fi
    # ★退格条数在**本机**算好、拼成一条一行命令发过去：以前写 `for i in $(seq 1 N); do …; done`，
    #   而 $() 在 Git Bash 里带进来的换行会原样落到远端命令里(实测读数变成 "for i in 1\n2\n3…")——
    #   能跑，但形状不由我控(例 138 那两颗 awk 雷的同一族：把算术交给别的壳去解释)。
    local q DELS=''
    for ((q = 0; q < ${#B} + ${#TERM} + 6; q++)); do DELS="$DELS; input keyevent 67"; done
    S "${DELS#; }" >/dev/null 2>&1
    sleep 1
    A=$(field_now)
    echo "    证空第 $j 轮：[$B] -> [$A]"
    [ "$A" = "$B" ] && echo "    ▲ 读数一字没变 ⇒ 退格这条腿可能没落到字段上(别再退，下一轮换打法)"
  done
  is_empty_field "$A" && { echo "    证空：清到最后是[$A] => 空"; return 0; }
  echo "  [!] 两轮都证明不了字段是空的(最后读到 [$A]；刚进来时是 [$UGBASE]) ⇒ **不往有字的字段里打字**"
  return 1
}
type_term_once() {
  local F j
  S "input text \"$TERM\"" >/dev/null 2>&1
  F=$(field_now)
  for j in 1 2; do
    [ "$F" = "$TERM" ] && break
    case "$TERM" in "$F"* ) : ;; *) break ;; esac     # 只有"是期望值的前缀"才值得再等——重打只会造 merge
    sleep 1
    F=$(field_now)
  done
  FIELD_LAST=$F
  [ "$F" = "$TERM" ] && { echo "    字段逐字 = $TERM"; return 0; }
  if [ -n "$F" ] && case "$TERM" in "$F"* ) true ;; *) false ;; esac; then
    echo "    [!] 只收到前缀 [$F] ⇒ 键还没落地"
  elif printf '%s' "$F" | grep -aq -- "$TERM"; then
    echo "    [!] [$F] 里粘了别的东西 ⇒ 残留相粘(过滤器拿整串匹配，多一字符就列空)"
  else
    echo "    [!] 字段 [$F] 与过滤词 $TERM 对不上 ⇒ 漏字/粘字"
  fi
  return 1
}
refocus_field() {
  local FX FY
  FX=""; FY=""
  read -r FX FY < build_ug_fld.txt 2>/dev/null || true
  if [[ "$FX" =~ ^[0-9]+$ && "$FY" =~ ^[0-9]+$ ]]; then S "input tap $FX $FY" >/dev/null 2>&1; sleep 1; return 0; fi
  echo "    (树里没读到字段中心 ⇒ 不重焦点)"
  return 1
}
srch_state() {
  : > build_ug_clean.txt; : > build_ug_field.txt; : > build_ug_fld.txt
  $PY - "$EV/ug_srch.xml" <<'PY'
import re,sys,io,os
p=sys.argv[1]; cl=''; fld=''; fxy=''
if os.path.exists(p) and os.path.getsize(p):
    s=io.open(p,encoding='utf-8',errors='replace').read()
    for m in re.finditer(r'<node[^>]*',s):
        t=m.group(0)
        if 'clickable="true"' not in t: continue
        b=re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',t)
        if not b: continue
        g=[int(x) for x in b.groups()]
        if g[3]>320: continue                     # 只看顶部搜索条那一带(第 111 发实测字段 y=143..287)
        txt=(re.search(r'text="([^"]*)"',t) or [None,''])[1]
        cd =(re.search(r'content-desc="([^"]*)"',t) or [None,''])[1]
        cx,cy=(g[0]+g[2])//2,(g[1]+g[3])//2
        # ★Clean 在 content-desc 里(text 是空的)——第 111 发对着真树打印才发现，别按 text 找它
        if cd=='Clean' and not cl: cl='%d %d' % (cx,cy)
        elif txt and txt!='取消' and not fld:
            fld=txt
            fxy='%d %d' % (cx,cy)                 # ★字段自己的中心：重新聚焦要点它，不能回点"展开搜索框"那个老坐标
io.open('build_ug_clean.txt','w',encoding='utf-8').write(cl)
io.open('build_ug_field.txt','w',encoding='utf-8').write(fld)
io.open('build_ug_fld.txt','w',encoding='utf-8').write(fxy)
print('  字段=[%s] Clean=%s 字段中心=%s' % (fld, cl or '没读到', fxy or '没读到'))
PY
}
dump_to() {
  local t=$1 k
  adb shell "rm -f /sdcard/ug.xml" >/dev/null 2>&1
  rm -f "$t"
  for k in 1 2; do
    adb shell "uiautomator dump /sdcard/ug.xml >/dev/null 2>&1; echo" >/dev/null 2>&1
    adb pull //sdcard/ug.xml "$t" >/dev/null 2>&1
    [ -s "$t" ] && { echo "  dump#$k -> $t $(wc -c < "$t") B"; return 0; }
    echo "  dump#$k 没产出文件(有前科那一类)，重试"; sleep 2
  done
  echo "  [!] dump 两跑都空 ⇒ 后面那格会按'dump 没成'处理，不会拿旧树下结论"
  return 1
}
ime_probe() {     # 0=能直接提交；9=不能(调用方据此停手，不去重试)
  local P
  S "input text \"q\"" >/dev/null 2>&1; sleep 1
  P=$(field_now)
  if [ "$P" = q ]; then
    echo "    探针：打 q 后字段逐字 = q ⇒ 输入法处于能直接提交的状态(拉丁/英文)"
    ime_cleanup || return 9
    return 0
  fi
  echo "    [!] 探针：打 q 之后字段读到 [$P]"
  case "$P" in
    ''|'搜索'|'搜索…'|'Search'|'搜索设置项'|'请输入搜索内容')
        echo "        ⇒ 一个字符都没提交＝字母进了拼音**合成区**(中文组合态)" ;;
    *)  echo "        ⇒ 提交出来的是别的东西＝输入法在做转换(全角/候选/联想)" ;;
  esac
  echo "        ★这一发不该继续打字，也不该判成「腿失败」：请在手机上切到英文/系统键盘再重跑(退出码 9)"
  ime_cleanup || true
  return 9
}
ime_cleanup() {   # 探针那个字符必须清回空并**读回**——绝不能把残留留给下一串(例 110 那一族)
  local B A CL CY q D=''
  B=$(field_now)
  CL=""; CY=""
  read -r CL CY < build_ug_clean.txt 2>/dev/null || true
  if [[ "$CL" =~ ^[0-9]+$ && "$CY" =~ ^[0-9]+$ ]]; then S "input tap $CL $CY" >/dev/null 2>&1; sleep 1; fi
  for ((q = 0; q < ${#B} + 6; q++)); do D="$D; input keyevent 67"; done
  S "${D#; }" >/dev/null 2>&1; sleep 1
  A=$(field_now)
  if is_empty_field "$A"; then echo "    探针收尾：[$B] -> [$A] 已清回空"; return 0; fi
  echo "  [!] 探针收尾：清完还读到 [$A] ⇒ 停手(别把探针的字符留给下一串)"
  return 1
}
try_latin_ime() {
  local CUR NEW='com.locnet.gamekeyboard2/.SoftKeyboard' G
  CUR=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
  if [ -z "$CUR" ]; then echo '    [!] 读不到当前输入法 ⇒ 不做切换(不敢瞎改不确定的状态)'; return 1; fi
  S "ime enable $NEW" >/dev/null 2>&1
  S "ime set $NEW"    >/dev/null 2>&1; sleep 2
  G=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
  if [ "$G" != "$NEW" ]; then echo "    [!] 切到 $NEW 没生效(读回 [$G]) ⇒ 不硬来"; return 1; fi
  IME_RESTORE="$CUR"
  echo "    已切到 $NEW(原 [$CUR])；★退出时装回(trap 兜住，含失败出口)"
  return 0
}
restore_ime() {
  # `${…:-}`：这份函数会被**离线夹具切片**（w459 只切函数体、不含上面的 `IME_RESTORE=''`），
  # 在 `set -u` 下裸写 `$IME_RESTORE` 会让**仪器**先崩（第 61 发之后跑总闸就红在这里）。
  [ -n "${IME_RESTORE:-}" ] || return 0
  S "ime set $IME_RESTORE" >/dev/null 2>&1; sleep 1
  local G; G=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
  if [ "$G" = "$IME_RESTORE" ]; then echo "    ✓ 输入法已装回 [$G]"
  else echo "    [!] 没装回去(读回 [$G]) ⇒ 请手工切回 $IME_RESTORE"; fi
  IME_RESTORE=''
}
IME_RESTORE="${IME_RESTORE:-}"
