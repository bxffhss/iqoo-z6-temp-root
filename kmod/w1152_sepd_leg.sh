#!/system/bin/sh
# w1152_sepd_leg.sh —— #238 部件①(核内解码)的设备侧预演腿。
# 做什么：把 `z6sepdec` 探针装进当前窗口，逐条把 PC 生成的**命令流夹具**喂进 /proc/w1151_in，
#         让内核里的解码器解，再把读数抄回证件，与 expect.txt 里那份**PC 独立算出的期望**对表。
# 不做什么：**不解析策略图、不碰 security_load_policy、不写 /sys/fs/selinux/ 任何东西、不翻执法。**
#   ⇒ 这一发买的是"同一段码在 aarch64 内核里跑出来的读数＝x86 宿主上跑出的读数"那一格。
# ★mksh 的脾气(本仓一手)：`echo` 不看 write 的返回码 ⇒ 判"写进去没有"一律**读回参数**，不信 echo 的 rc；
#   写二进制用 `dd`(它看返回码)；节拍只用 `sleep`；取键先锚到那一行(例 231：同一个键名会在一行里出现)。
# ★§293 的纪律：被测自己带默认关着的分段开关，调用方**显式传值＋把参数本身回抄进证件**——
#   `pd_slots` 每一次 insmod 都显式给，并读回 `$PM/pd_slots` 印在组头上。
# 需要的设备侧文件(都由 PC 侧链 push；腿只验身份，不生成)：
#   $FIX/<夹具>.bin 若干、$TBL(expect.txt，与 PC 同一条)、$KO(z6sepdec.ko)
# ctl.txt 的键(缺一个就停——"参数没传到"就是空枪的形状)：
#   KO_MD5=<出货前那枚件的 md5>  TBL_MD5=<期望表的 md5>  [KO=..] [FIX=..] [TBL=..] [OUT=..] [KEEP=0]
set -u
P=${OUT_DIR:-/data/local/tmp/w1152}
CTL=${CTL:-$P/ctl.txt}
getk() { sed -n "s/^$1=//p" "$CTL" 2>/dev/null | tail -1; }
FIX=${FIX:-$(getk FIX)};  FIX=${FIX:-$P/fixtures}
TBL=${TBL:-$(getk TBL)};  TBL=${TBL:-$P/expect.txt}
KO=${KO:-$(getk KO)};     KO=${KO:-$P/z6sepdec.ko}
KOMD5_WANT=$(getk KO_MD5)
TBLD5_WANT=$(getk TBL_MD5)
OUT=${OUT:-$(getk OUT)};  OUT=${OUT:-$P/leg.out}
KEEP=${KEEP:-$(getk KEEP)}; KEEP=${KEEP:-0}
ERRF=$P/leg.err
MOD=z6sepdec
PM=/sys/module/$MOD/parameters
INF=/proc/w1151_in
CTLF=/proc/w1151_ctl

mkdir -p "$P" 2>/dev/null
: >"$ERRF" 2>/dev/null
: >"$OUT" 2>>"$ERRF"
say() { printf '%s\n' "$*" >>"$OUT" 2>>"$ERRF"; sync; }
rd()  { cat "$1" 2>>"$ERRF"; }
par() { cat "$PM/$1" 2>>"$ERRF"; }
up()  { cut -d. -f1 /proc/uptime 2>/dev/null; }
modcnt() { grep -c "^$MOD " /proc/modules 2>/dev/null; }
# 从**一行**里取一个键(调用方先把那一行锚好)
kv()  { sed -n "s/.* $1=\([^ ]*\).*/\1/p" | head -1; }

say "BEGIN v1152 up=$(up) boot_id=$(rd /proc/sys/kernel/random/boot_id)"
say "LEG enf=$(rd /sys/fs/selinux/enforce) uname=$(uname -r)"
say "LEG ko=$KO ko_md5=$(md5sum "$KO" 2>/dev/null | cut -d' ' -f1) ko_md5_want=$KOMD5_WANT"
say "LEG tbl=$TBL tbl_md5=$(md5sum "$TBL" 2>/dev/null | cut -d' ' -f1) tbl_md5_want=$TBLD5_WANT"
say "LEG fix=$FIX fix_ls=$(ls "$FIX" 2>/dev/null | tr '\n' ',' ) ctl_raw=$(tr '\n' '|' <"$CTL" 2>/dev/null)"

# 0) 身份闸：件与表都要在，且 md5 必须与 ctl.txt 给的一致(不一致⇒不试，别拿陈件当读数)
[ -f "$KO" ]  || { say "FAIL=ko 不在"; say "END up=$(up)"; exit 1; }
[ -f "$TBL" ] || { say "FAIL=期望表不在"; say "END up=$(up)"; exit 1; }
[ -n "$KOMD5_WANT" ] || { say "FAIL=ctl.txt 没给 KO_MD5⇒这格未测，不许开跑"; say "END up=$(up)"; exit 1; }
[ -n "$TBLD5_WANT" ] || { say "FAIL=ctl.txt 没给 TBL_MD5⇒这格未测，不许开跑"; say "END up=$(up)"; exit 1; }
GOTKO=$(md5sum "$KO" 2>/dev/null | cut -d' ' -f1)
GOTTBL=$(md5sum "$TBL" 2>/dev/null | cut -d' ' -f1)
if [ "$GOTKO" != "$KOMD5_WANT" ]; then say "FAIL=件 md5 不符 got=$GOTKO want=$KOMD5_WANT"; say "END up=$(up)"; exit 1; fi
if [ "$GOTTBL" != "$TBLD5_WANT" ]; then say "FAIL=表 md5 不符 got=$GOTTBL want=$TBLD5_WANT"; say "END up=$(up)"; exit 1; fi
say "IDENTITY=ok"

PASS=0; FAILN=0

# 1) 装件并证明参数面真的在(参数面不在⇒后面全是空读数)
load_with() { # load_with <slots>
  rmmod $MOD 2>>"$ERRF"
  insmod "$KO" pd_slots="$1" pd_verbose=1 2>>"$ERRF"
  rc=$?
  say "GROUP slots_want=$1 insmod_rc=$rc modcnt=$(modcnt) pd_slots=$(par pd_slots) pd_abi=$(par pd_abi) pd_verbose=$(par pd_verbose)"
  [ "$rc" = 0 ] || { say "FAIL=insmod 非 0"; return 1; }
  [ "$(par pd_slots)" = "$1" ] || { say "FAIL=pd_slots 读回≠传进去的值(§293 那一族：参数没传进去⇒格是空的)"; return 1; }
  [ -r "$INF" ] && [ -r "$CTLF" ] || { say "FAIL=/proc 两口不在"; return 1; }
  return 0
}

# 2) 一格：RESET→喂→DECODE→抄读数→与期望对表→再把内核里那份原样读回算 md5/FNV
one_case() { # one_case <case名> <文件名>
  name="$1"; file="$2"
  L=$(grep "^$name " "$TBL" 2>/dev/null | head -1)
  [ -n "$L" ] || { say "CASE $name bad=表里没这行(读法错还是表旧了?)"; FAILN=$((FAILN+1)); return; }
  w_md5=$(echo "$L" | kv md5);  w_fnv=$(echo "$L" | kv fnv)
  w_bytes=$(echo "$L" | kv bytes); w_why=$(echo "$L" | kv why)
  w_n=$(echo "$L" | kv n); w_at=$(echo "$L" | kv bad_at)
  w_ma=$(echo "$L" | kv max_arg); w_lm=$(echo "$L" | kv lenmatch)
  # ★例 222 那一族：取数取到空串⇒[ "" = "" ] 会"全对"。先把期望本身验齐，缺一个键就把这格判坏。
  for v in "$w_md5" "$w_fnv" "$w_bytes" "$w_why" "$w_n" "$w_at" "$w_ma" "$w_lm"; do
    [ -n "$v" ] || { say "CASE $name bad=期望表这行缺键(L=[$L])"; FAILN=$((FAILN+1)); return; }
  done
  f="$FIX/$file"
  if [ ! -f "$f" ]; then say "CASE $name bad=夹具不在($f)"; FAILN=$((FAILN+1)); return; fi
  g_bytes=$(wc -c <"$f" 2>/dev/null | tr -d ' ')
  g_md5=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)
  if [ "$g_bytes" != "$w_bytes" ] || [ "$g_md5" != "$w_md5" ]; then
    say "CASE $name bad=设备上的夹具与表不符 bytes=$g_bytes/$w_bytes md5=$g_md5/$w_md5"
    FAILN=$((FAILN+1)); return
  fi
  echo RESET >"$CTLF" 2>>"$ERRF"
  dd if="$f" of="$INF" bs=4096 2>>"$ERRF"; ddrc=$?
  echo DECODE >"$CTLF" 2>>"$ERRF"
  r_why=$(par pd_why); r_n=$(par pd_n); r_at=$(par pd_bad_at)
  r_ma=$(par pd_max_arg); r_lm=$(par pd_lenmatch); r_bytes=$(par pd_bytes); r_sum=$(par pd_sum)
  dd if="$INF" of="$P/rb_$name" bs=4096 2>>"$ERRF"
  r_md5=$(md5sum "$P/rb_$name" 2>/dev/null | cut -d' ' -f1)
  rd "$CTLF" >"$P/rec_$name" 2>/dev/null
  r_stmts=$(grep -c '^STMT ' "$P/rec_$name" 2>/dev/null); r_stmts=${r_stmts:-0}
  r_trunc=$(par pd_rec_trunc); r_recb=$(par pd_rec_bytes)
  for v in "$r_why" "$r_n" "$r_at" "$r_ma" "$r_lm" "$r_bytes" "$r_sum" "$r_md5" "$r_trunc"; do
    [ -n "$v" ] || { say "CASE $name bad=内核读数里有空值(取数或参数面出问题了，不是『解错了』)"; FAILN=$((FAILN+1)); return; }
  done
  say "CASE $name ddrc=$ddrc in_bytes=$r_bytes in_md5=$r_md5 in_fnv=$r_sum why=$r_why n=$r_n bad_at=$r_at max_arg=$r_ma lenmatch=$r_lm rec_stmts=$r_stmts rec_trunc=$r_trunc rec_bytes=$r_recb want(why=$w_why n=$w_n at=$w_at ma=$w_ma lm=$w_lm bytes=$w_bytes md5=$w_md5 fnv=$w_fnv)"
  ok=1
  [ "$r_why" = "$w_why" ] || ok=0
  [ "$r_n" = "$w_n" ] || ok=0
  [ "$r_at" = "$w_at" ] || ok=0
  [ "$r_ma" = "$w_ma" ] || ok=0
  [ "$r_lm" = "$w_lm" ] || ok=0
  [ "$r_bytes" = "$w_bytes" ] || ok=0
  [ "$r_sum" = "$w_fnv" ] || ok=0
  # ★读回那份的 md5 必须等于 PC 那一份：这是"内核里 staged 的字节＝我送进去的字节"的独立证人，
  #   与上面那些"解码读数对不对"是两件事(一件讲字节，一件讲解析)。
  [ "$r_md5" = "$w_md5" ] || ok=0
  # 记录渲染：why=0 且没截断⇒该有 n 行；why≠0⇒一行都不该有(REJECT 分支明写不许印)
  if [ "$w_why" = 0 ]; then
    if [ "$r_trunc" = 0 ] && [ "$r_stmts" != "$w_n" ]; then ok=0; fi
    if [ "$r_trunc" = 1 ] && [ "$r_stmts" -ge "$w_n" ]; then ok=0; fi
  elif [ "$r_stmts" != 0 ]; then ok=0; fi
  if [ "$ok" = 1 ]; then PASS=$((PASS+1)); say "CASEOK $name 1"; else FAILN=$((FAILN+1)); say "CASEOK $name 0"; fi
}

# 3) 按表里的 slots 分组跑(变体＝同一份字节换 pd_slots，需要重装一次)
# ★变量名要躲开 bash 的保留数组 `GROUPS`(它在 bash 4.4+ 是"进程有效组 ID"，赋值会被无声忽略；
#   自测第一次就在这格里拿到一个像 PID 的数)。腿本该跑在 mksh，但名字撞了就是隐患 ⇒ 用 SLOTGRP。
SLOTGRP=$(awk '!/^#/ { for(i=1;i<=NF;i++) if($i ~ /^slots=/) print substr($i,7) }' "$TBL" | sort -u)
say "SLOTGRP=$SLOTGRP"
for g in $SLOTGRP; do
  if ! load_with "$g"; then say "GROUP_SKIP slots=$g"; FAILN=$((FAILN+1)); continue; fi
  for pair in $(awk -v s="$g" '!/^#/ { sl=""; fl=""; for(i=1;i<=NF;i++){ if($i ~ /^slots=/) sl=substr($i,7); if($i ~ /^file=/) fl=substr($i,6) } if(sl==s) print $1 "." fl }' "$TBL"); do
    one_case "$(echo "$pair" | cut -d. -f1)" "$(echo "$pair" | cut -d. -f2-)"
  done
done

# 4) 空流那一格：RESET 之后直接 DECODE ⇒ 内核该拒(不计数、不改读数)
#    ★这一格同时是把"没输出"和"输出为 0"分开的证人：calls 不涨＋why 仍是 -1 才叫"根本没解"。
C0=$(par pd_calls)
echo RESET >"$CTLF" 2>>"$ERRF"
echo DECODE >"$CTLF" 2>>"$ERRF"
C1=$(par pd_calls); W=$(par pd_why); N=$(par pd_n)
say "EMPTY_CTRL calls0=$C0 calls1=$C1 why=$W n=$N"
if [ -n "$C0" ] && [ "$C0" = "$C1" ] && [ "$W" = "-1" ] && [ "$N" = "-1" ]; then
  PASS=$((PASS+1)); say "CASEOK EMPTY_CTRL 1"
else
  FAILN=$((FAILN+1)); say "CASEOK EMPTY_CTRL 0"
fi

# 5) 收尾：探针必须 rmmod(关窗铁律：依赖模块的一切都排在恢复执法之前)
if [ "$KEEP" = 1 ]; then
  say "KEEP=1 ⇒ 不 rmmod(只在这次实验里保留)"
else
  rmmod $MOD 2>>"$ERRF"; urc=$?
  say "RMMOD rc=$urc modcnt=$(modcnt)"
  if [ "$urc" = 0 ] && [ "$(modcnt)" = 0 ]; then PASS=$((PASS+1)); say "CASEOK RMMOD 1";
  else FAILN=$((FAILN+1)); say "CASEOK RMMOD 0"; fi
fi
say "COUNTS pass=$PASS fail=$FAILN enf=$(rd /sys/fs/selinux/enforce) uname=$(uname -r)"
say "END up=$(up)"
