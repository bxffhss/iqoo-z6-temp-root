#!/bin/bash
# w1159_run.sh —— 本地包装(0 枪)：#241 的三道本地证据＋把用户态那一头送去构建机跑自测。
#   [A] 候选二进制：NDK 编两遍 md5 相同，PT_TLS 由 build_ksuctl.sh 自己断言；★出货件 ksuctl86 不许动。
#   [B] 静态闸：cmd_setsepol 里"那道门之前碰不到驱动"——带一份**变异副本**当反向对照(不然这条闸
#       数到的 0 只是"锚没找到"，不是"没发生"；见 [[feedback-probe-false-positives]] 例 231/235)。
#   [C] 远端自测：纯逻辑在 x86 宿主跑绿＋五条变异全被抓＋还原仍绿(判决只认远端印出来的行)。
# 用法：HRMT_CLI=hermes-remote1/cli.py bash kmod/w1159_run.sh [证件名] [超时秒]
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-w1159_host_v1}"
T="${2:-600}"
EV="$D/kmod/w103_evidence"
SRC="$D/cm57/ksuctl.c"
WIRE="$D/kmod/w1159_sepol_wire.h"
CORE="$D/kmod/w1151_sepolicy_core.h"
REC="$D/kmod/w1155_sepol_record.h"
MAIN="$D/kmod/w1159_host_selftest.c"
SUP="$D/kmod/uapi/supercall.h"
APF="$D/kmod/uapi/app_profile.h"
FIX="$D/kmod/w1152_fixtures"
RDIR="$EV/w1153_records_shot97"
SHIP="$D/kmod/ksuctl86"
CAND="$D/cm57/ksuctl_241_v1"

for f in "$SRC" "$WIRE" "$CORE" "$REC" "$MAIN" "$SUP" "$APF" "$SHIP"; do
  [ -s "$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
[ -s "$FIX/expect.txt" ] || { echo "!! 期望表不在(先跑 python kmod/w1152_sepd_fixtures.py)"; exit 1; }
L_WIRE=$(md5sum "$WIRE" | cut -d' ' -f1); L_CORE=$(md5sum "$CORE" | cut -d' ' -f1)
L_REC=$(md5sum "$REC" | cut -d' ' -f1);   L_MAIN=$(md5sum "$MAIN" | cut -d' ' -f1)
L_SUP=$(md5sum "$SUP" | cut -d' ' -f1);   L_APF=$(md5sum "$APF" | cut -d' ' -f1)
echo "本地 md5：线层=$L_WIRE 核心=$L_CORE 记录层=$L_REC 自测源=$L_MAIN"
echo "          supercall=$L_SUP app_profile=$L_APF 出货 ksuctl86=$(md5sum "$SHIP" | cut -d' ' -f1)"

BAD=0
echo "=== [A] 候选二进制：NDK 编两遍 ==="
MB1=1; MB2=1
bash "$D/cm57/build_ksuctl.sh" "$CAND" >"$EV/${N}_build1.log" 2>&1; MB1=$?
B1=$(md5sum "$CAND" 2>/dev/null | cut -d' ' -f1)
bash "$D/cm57/build_ksuctl.sh" "$CAND" >"$EV/${N}_build2.log" 2>&1; MB2=$?
B2=$(md5sum "$CAND" 2>/dev/null | cut -d' ' -f1)
echo "  build1 rc=$MB1 md5=${B1:-空} build2 rc=$MB2 md5=${B2:-空}"
[ "$MB1" = 0 ] && [ "$MB2" = 0 ] || { echo "[BAD] NDK 构建没通过(rc1=$MB1 rc2=$MB2)⇒ 看 $EV/${N}_build2.log"; BAD=1; }
[ -n "$B1" ] && [ "$B1" = "$B2" ] && echo "[ok] 同一份源码两次独立构建同 md5：$B1" || { echo "[BAD] 构建不可复现 b1=${B1:-空} b2=${B2:-空}"; BAD=1; }
for i in 1 2; do
  AL=$(grep -ao 'PT_TLS align=[0-9][0-9]*' "$EV/${N}_build$i.log" | head -1 | cut -d= -f2)
  [ "${AL:-0}" -ge 64 ] && echo "[ok] build$i PT_TLS align=$AL(加载器要 >=64)" || { echo "[BAD] build$i 没抓到 PT_TLS align>=64 的读数(抓到的是\"${AL:-空}\")⇒ 这条二进制上机第一句就 Aborted"; BAD=1; }
done
SH=$(md5sum "$SHIP" | cut -d' ' -f1)
[ "$SH" != "${B1:-}" ] && [ -n "$B1" ] && echo "[ok] 候选($B1) ≠ 出货 ksuctl86($SH) ⇒ 没覆盖到货" || { echo "[BAD] 候选与出货件同 md5(或候选为空) ⇒ 货/账都要重看"; BAD=1; }
# ★"货未动"的对端不是我自己背的常数，是文档里登记过的那行(ROUTE-B:4417 `ksuctl86 v4(md5 …)`)
DOC=$(grep -ao 'ksuctl86 v4(md5 [0-9a-f]\{32\}' "$D/kmod/ROUTE-B-OFFSET-INVERSION.md" | tail -1 | grep -ao '[0-9a-f]\{32\}')
if [ -n "$DOC" ]; then
  [ "$DOC" = "$SH" ] && echo "[ok] 出货件 md5 与文档登记一致：$DOC" || { echo "[BAD] 出货件=$SH 文档登记=$DOC ⇒ 货与账不符"; BAD=1; }
else
  echo "[BAD] 文档里没抓到那条登记 ⇒ 这条对照没跑成(数不到不等于通过)"
  BAD=1
fi

echo "=== [B] 静态闸：门之前碰不到驱动 ==="
scan_gate() { # <c 文件> ⇒ "ioctl=<次> drive_fd=<次> 段行数=<n>"；只数 cmd_setsepol 里 `gate = w1159_gate(` **之前**
  local f="$1" seg n d lines
  seg=$(awk '/^static int cmd_setsepol/{f=1} f&&/gate = w1159_gate\(/{exit} f{print}' "$f")
  lines=$(printf '%s\n' "$seg" | grep -c '')
  n=$(printf '%s\n' "$seg" | grep -ao 'ioctl(' | wc -l | tr -dc '0-9')
  d=$(printf '%s\n' "$seg" | grep -ao 'drive_fd(' | wc -l | tr -dc '0-9')
  echo "ioctl=${n:-0} drive_fd=${d:-0} seglines=$lines"
}
G=$(scan_gate "$SRC")
echo "  真件：$G"
printf '%s\n' "$G" | grep -q 'ioctl=0 drive_fd=0' && [ "$(printf '%s' "$G" | grep -ao 'seglines=[0-9]*' | cut -d= -f2)" -ge 20 ] \
  && echo "[ok] 门之前零次 ioctl/零次 drive_fd，且那段确实有 20 行以上(不是空段)" \
  || { echo "[BAD] 门之前碰了驱动，或者那段是空的(空段的 0 不算证据)：$G"; BAD=1; }
# ★反向对照：把一条 ioctl 复制到门之前，同一把尺必须报红 ⇒ 证明上面那个 0 是"没发生"不是"没数到"
cp "$SRC" "$EV/${N}_mutgate.c"
sed -i "/SETSEPOL path=/a\\	r = ioctl(fd, KSU_IOCTL_SET_SEPOLICY, &c); /* 变异:把发的那一步挪到门之前 */" "$EV/${N}_mutgate.c"
GM=$(scan_gate "$EV/${N}_mutgate.c")
printf '%s\n' "$GM" | grep -q 'ioctl=0 drive_fd=0' && { echo "[BAD] 变异件仍报 0 ⇒ 这把静态闸是恒绿的空尺：$GM"; BAD=1; } || echo "[ok] 变异件被抓：$GM"
rm -f "$EV/${N}_mutgate.c"
# ★另一头的对照：整个函数不在的时候这把尺该报"空段"(证明 seglines 那把尺有牙)
printf 'nope\n' >"$EV/${N}_noresrc.c"
GN=$(scan_gate "$EV/${N}_noresrc.c")
printf '%s\n' "$GN" | grep -q 'seglines=1$' && echo "[ok] 抓到了\"函数不在\"的形状：$GN(所以 seglines 那把尺不是摆设)" || echo "  (提示) 没有函数时这把尺读到：$GN"
rm -f "$EV/${N}_noresrc.c"

echo "=== [B2] 自测源先在本机过一遍 clang(-Wall -Wextra，编的是 aarch64 目标但只 -c 不跑) ==="
CC2="$D/ndk/android-ndk-r26b/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android21-clang"
[ -x "$CC2" ] || { echo "[BAD] 找不到 NDK clang ⇒ 这一格没跑(不等于通过)"; BAD=1; }
if [ -x "$CC2" ]; then
  "$CC2" -std=gnu11 -O2 -Wall -Wextra -I "$D/kmod" -c "$MAIN" -o "$EV/${N}_selftest.o" 2>"$EV/${N}_selftest_cc.txt"
  echo "  clang rc=$? 诊断见 $EV/${N}_selftest_cc.txt"
  NW=$(grep -ac 'warning:' "$EV/${N}_selftest_cc.txt"); NE=$(grep -ac 'error:' "$EV/${N}_selftest_cc.txt")
  [ "$NW" = 0 ] && [ "$NE" = 0 ] && echo "[ok] 自测源零 warning 零 error(clang/-Wall/-Wextra)" || { echo "[BAD] clang 预检有诊断 warn=$NW err=$NE(远端是 gcc＋-Werror，先在这里拦掉省一趟)"; BAD=1; }
  # ★正对照：把注释改成"块注释里再开一块"这种必报警状的形状(只在原注释开头插 `/* `，行尾的 `*/` 仍是
  #   唯一闭合点 ⇒ 语法不破，只出 warning)，同一把尺必须数到非零 ⇒ 上面那个 0 不是空尺。
  sed 's|/\* 命令字手抄自|/* /* 命令字手抄自|' "$MAIN" >"$EV/${N}_selftest_mut.c"
  "$CC2" -std=gnu11 -O2 -Wall -Wextra -I "$D/kmod" -c "$EV/${N}_selftest_mut.c" -o "$EV/${N}_selftest_mut.o" 2>"$EV/${N}_selftest_mutcc.txt"
  MZW=$(grep -ac 'warning:' "$EV/${N}_selftest_mutcc.txt")
  [ "$MZW" -ge 1 ] && echo "[ok] 变异预检被抓(数到 $MZW 条 warning ⇒ 上面那个 0 是有牙的)" || { echo "[BAD] 变异预检没抓到(0 条 warning ⇒ 这把预检是恒绿的)"; BAD=1; }
  rm -f "$EV/${N}_selftest_mut.c" "$EV/${N}_selftest_mut.o"
  rm -f "$EV/${N}_selftest.o"
fi

echo "=== [C] 送构建机跑宿主自测 ==="
CLI="${HRMT_CLI:-$D/hermes-remote/cli.py}"; CFG="${HRMT_CONFIG:-$(dirname "$CLI")/config.json}"
{ [ -f "$CLI" ] && [ -f "$CFG" ]; } || { echo "!! 端点不对：CLI=$CLI CFG=$CFG"; exit 1; }
TARLIST=$(cd "$FIX" && ls *.bin expect.txt | tr '\n' ' ')
tar -C "$FIX" -cf "$EV/w1159_fix.tar" $TARLIST || { echo "!! 夹具打包失败"; exit 1; }
RECLIST=$(cd "$RDIR" && ls rec_* | tr '\n' ' ')
tar -C "$RDIR" -cf "$EV/w1159_rec.tar" $RECLIST || { echo "!! 设备证件打包失败"; exit 1; }
echo "  夹具包=$(wc -c <"$EV/w1159_fix.tar" | tr -dc '0-9') 字节 证件包=$(wc -c <"$EV/w1159_rec.tar" | tr -dc '0-9') 字节"

put_one() {
  local src="$1" dst="$2" out rc
  out=$(PYTHONUTF8=1 python "$CLI" --config "$CFG" put "$src" "$dst" 2>&1); rc=$?
  echo "  put $dst rc=$rc (真证人＝下面两端 md5 那一格)"
  [ "$rc" = 0 ] || { echo "!! put $dst 失败 ⇒ 停"; exit 1; }
}
put_one "$WIRE" w1159_wire.h
put_one "$CORE" w1151_core.h
put_one "$REC"  w1155_record.h
put_one "$SUP"  w1159_supercall.h
put_one "$APF"  w1159_app_profile.h
put_one "$MAIN" w1159_main.c
put_one "$EV/w1159_fix.tar" w1159_fix.tar
put_one "$EV/w1159_rec.tar" w1159_rec.tar

bash "$D/kmod/w999_runcap.sh" kmod/w1159_remote.sh "$N" "$T" >"$EV/${N}.wrap.log" 2>&1
echo "run rc=$?"
OUT="$EV/${N}.txt"
[ -f "$OUT" ] || { echo "!! 没有产物 $OUT ⇒ 判失败"; exit 1; }

g1() { grep -ao "^MD5_$1=[0-9a-f]\{32\}" "$OUT" | head -1 | cut -d= -f2; }
L_FIXTAR=$(md5sum "$EV/w1159_fix.tar" | cut -d' ' -f1)
L_RECTAR=$(md5sum "$EV/w1159_rec.tar" | cut -d' ' -f1)
for pair in "w1159_wire.h=$L_WIRE" "w1151_core.h=$L_CORE" "w1155_record.h=$L_REC" "w1159_main.c=$L_MAIN" "w1159_supercall.h=$L_SUP" "w1159_app_profile.h=$L_APF" "w1159_fix.tar=$L_FIXTAR" "w1159_rec.tar=$L_RECTAR"; do
  k=${pair%%=*}; want=${pair#*=}; got=$(g1 "$k")
  [ "$got" = "$want" ] && echo "[ok] 两端同 md5：$k" || { echo "[BAD] $k 远端=${got:-空} 本地=$want"; BAD=1; }
done
grep -aq '^FIXTURES_BINS=11$' "$OUT" || { echo "[BAD] 远端夹具不是 11 件"; BAD=1; }
grep -aq '^TBL_LINES=12$' "$OUT"     || { echo "[BAD] 远端期望表不是 12 行"; BAD=1; }
grep -aq '^REC_FILES=12$' "$OUT"     || { echo "[BAD] 远端设备证件不是 12 份"; BAD=1; }
grep -aq '^REC_PDV1=12$' "$OUT"      || { echo "[BAD] 12 份证件里第一行是 PD v1 的不足 12 ⇒ 证人形状不对"; BAD=1; }
grep -aq '^HOST_MAKE_RC=0$' "$OUT"   || { echo "[BAD] 宿主编译没通过"; BAD=1; }
grep -aq '^DIAG_ERR=0 DIAG_WARN=0$' "$OUT" || { echo "[BAD] 宿主编译有诊断(带 -Werror ⇒ 不该过)"; BAD=1; }
grep -aq '^RUN_RC=0$' "$OUT"         || { echo "[BAD] 正跑没绿"; BAD=1; }
# ★证件里必须带着"对表跑到了哪一格"的原文：只有 OK 行数和 SUM，日后分不清"12 格全等"与"压根没进那格"
NOKL=$(grep -ac '^  okline: ' "$OUT")
[ "$NOKL" = 4 ] || { echo "[BAD] 抄进证件的 okline 是 $NOKL 条(该 4 条：S1/S3/S5/S7)"; BAD=1; }
grep -aF 'S3 对期望表(模型)红=0；S4 对设备证件(证人)红=0' "$OUT" >/dev/null || { echo "[BAD] 证件里没有那句『12 格双向对表红=0/0』"; BAD=1; }
grep -a '^  okline: ' "$OUT" | sed 's/^/  /'
grep -aq 'SUM asserts=[0-9]\{1,6\} fails=0$' "$OUT" || { echo "[BAD] 自测的 SUM 那行不是 fails=0"; BAD=1; }
grep -aq 'VERDICT=w1159_pass' "$OUT" || { echo "[BAD] 自测 VERDICT 不是 pass"; BAD=1; }
N5=$(grep -ac '^MUT_.*=CAUGHT' "$OUT")
[ "$N5" = 5 ] || { echo "[BAD] 五条变异里只抓到 $N5 条(应当 5：fnvprime/capbound/expectone/fillptr/gatealways)"; BAD=1; }
grep -a '^MUT_' "$OUT" | sed 's/^/  /'
grep -aqE '^REVERT_RC=0([ (]|$)' "$OUT" || { echo "[BAD] 还原后没跑绿 ⇒ 变异可能留在了件里"; BAD=1; }
grep -aq '^VERDICT=ok' "$OUT" || { echo "[BAD] 远端总判据没到 ok"; BAD=1; }
echo "  自测行数：$(grep -a '^OK_LINES=' "$OUT")"

echo "=== 结论 ==="
if [ "$BAD" = 0 ]; then
  echo "VERDICT=w1159_green #241 用户态那一头判正(候选二进制 cm57/ksuctl_241_v1=$B1；货未动；设备一发没打)"
else
  echo "VERDICT=w1159_red 上面每条 [BAD] 都是**仪器或输入面**的红，不是被测；先修前置再谈上机"
fi
exit 0
