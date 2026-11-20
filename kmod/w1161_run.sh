#!/bin/bash
# w1161_run.sh —— 本地包装(0 枪)：把 #238 部件③「装载门」的纯判定＋第 96 发那两张真图
#   一起送构建机跑自测(正跑＋五条变异)，判决只认远端印出来的行。
# ★两条本地证据先跑：①本机 clang 预检(带远端同款 flag，省一趟往返)；
#   ②**上传的图必须还是那张图**——拿第 96 发腿证件里设备自己印的 `before_md5/after_md5` 对表，
#     不是我记的常数(§6.548 立的"对表要拿登记过的那行")。
# 用法：HRMT_CLI=hermes-remote1/cli.py bash kmod/w1161_run.sh [证件名] [超时秒]
set -u
export PYTHONUTF8=1
D="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-w1161_host_v1}"
T="${2:-600}"
cd "$D" || exit 1
# ★adb/远端工具的本地参数一律用相对名(§6.549 那条 MSYS_NO_PATHCONV 的坑)，绝对 `$D/…` 只给本地读写用。
EV=kmod/w103_evidence
GATE=kmod/w1161_polgate.h
WIRE=kmod/w1159_sepol_wire.h
CORE=kmod/w1151_sepolicy_core.h
REC=kmod/w1155_sepol_record.h
SUP=kmod/uapi/supercall.h
APF=kmod/uapi/app_profile.h
MAIN=kmod/w1161_host_selftest.c
IMGDIR=$EV/w1143_records_shot96
LEG96=$EV/w1143_leg_shot96.out
CC2=$D/ndk/android-ndk-r26b/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android21-clang

BAD=0
for f in "$GATE" "$WIRE" "$CORE" "$REC" "$SUP" "$APF" "$MAIN" "$LEG96" "$IMGDIR/pol.before" "$IMGDIR/pol.after"; do
  [ -s "$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
L_GATE=$(md5sum "$GATE" | cut -d' ' -f1); L_WIRE=$(md5sum "$WIRE" | cut -d' ' -f1)
L_CORE=$(md5sum "$CORE" | cut -d' ' -f1); L_REC=$(md5sum "$REC" | cut -d' ' -f1)
L_MAIN=$(md5sum "$MAIN" | cut -d' ' -f1)
echo "本地 md5：门=$L_GATE 线层=$L_WIRE 核心=$L_CORE 记录层=$L_REC 自测源=$L_MAIN"

echo "=== [A] 图的身份：与第 96 发设备自己印的 md5 对表(不背常数) ==="
DEV_B=$(grep -ao 'before_md5=[0-9a-f]\{32\}' "$LEG96" | head -1 | cut -d= -f2)
DEV_A=$(grep -ao 'after_md5=[0-9a-f]\{32\}' "$LEG96" | head -1 | cut -d= -f2)
LOC_B=$(md5sum "$IMGDIR/pol.before" | cut -d' ' -f1)
LOC_A=$(md5sum "$IMGDIR/pol.after" | cut -d' ' -f1)
echo "  证件里：before=$DEV_B after=$DEV_A"
echo "  现  读：before=$LOC_B after=$LOC_A"
[ -n "$DEV_B" ] && [ "$DEV_B" = "$LOC_B" ] && echo "  [ok] pol.before 还是那一发设备导出的那张" || { echo "  [BAD] pol.before 与证件登记的 md5 不符(或证件里没抓到)⇒ 证人换了图，后面全不算"; BAD=1; }
[ -n "$DEV_A" ] && [ "$DEV_A" = "$LOC_A" ] && echo "  [ok] pol.after 同上" || { echo "  [BAD] pol.after 与证件登记的 md5 不符"; BAD=1; }
[ "$LOC_B" != "$LOC_A" ] && echo "  [ok] 两张图彼此不同(装载确实换了东西＝第 96 发那条『policydb_write 不是不动点』的形状还在)" || { echo "  [BAD] 两张图一样了 ⇒ 上传的成对图坏了"; BAD=1; }

echo "=== [B] 本机 clang 预检(远端同款 flag，省一趟往返) ==="
[ -x "$CC2" ] || { echo "[BAD] 找不到 NDK clang ⇒ 这一格没跑(不等于通过)"; BAD=1; }
if [ -x "$CC2" ]; then
  "$CC2" -std=gnu11 -O2 -Wall -Wextra -Wno-unused-const-variable -Wno-unused-function -I kmod -c "$MAIN" -o "$EV/${N}_precheck.o" 2>"$EV/${N}_precheck_cc.txt"
  echo "  clang rc=$?"
  NW=$(grep -ac 'warning:' "$EV/${N}_precheck_cc.txt"); NE=$(grep -ac 'error:' "$EV/${N}_precheck_cc.txt")
  [ "$NW" = 0 ] && [ "$NE" = 0 ] && echo "[ok] 预检零诊断(两类 unused 是按 §6.549 的口径显式关掉的，证件里写了原因)" || { echo "[BAD] 预检有诊断 warn=$NW err=$NE"; BAD=1; }
  # ★这一格只是**预检**(省一趟往返)：它的牙不在这里，在远端那五条变异上。
  #   上一版我在这里放了一条"sed 改个字节说改动成功了"的假对照——那证的不是尺，是 sed 动了文件。
  rm -f "$EV/${N}_precheck.o"
fi

echo "=== [C] 送构建机 ==="
CLI="${HRMT_CLI:-$D/hermes-remote/cli.py}"; CFG="${HRMT_CONFIG:-$(dirname "$CLI")/config.json}"
{ [ -f "$CLI" ] && [ -f "$CFG" ]; } || { echo "!! 端点不对：CLI=$CLI CFG=$CFG"; exit 1; }
tar -C "$IMGDIR" -cf "$EV/w1161_img.tar" pol.before pol.after || { echo "!! 打包失败"; exit 1; }
echo "  图包=$(wc -c <"$EV/w1161_img.tar" | tr -dc '0-9') 字节"
L_IMGTAR=$(md5sum "$EV/w1161_img.tar" | cut -d' ' -f1)
L_LEG96=$(md5sum "$LEG96" | cut -d' ' -f1)
L_SUP=$(md5sum "$SUP" | cut -d' ' -f1); L_APF=$(md5sum "$APF" | cut -d' ' -f1)

put_one() {
  local out rc
  out=$(PYTHONUTF8=1 python "$CLI" --config "$CFG" put "$1" "$2" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then echo "  [ok] put $2 rc=$rc"; else echo "  [BAD] put $2 rc=$rc ⇒ $out"; BAD=1; fi
}
put_one "$GATE" w1161_gate.h
put_one "$WIRE" w1159_wire.h
put_one "$CORE" w1151_core.h
put_one "$REC"  w1155_record.h
put_one "$SUP"  w1161_supercall.h
put_one "$APF"  w1161_app_profile.h
put_one "$MAIN" w1161_main.c
put_one "$EV/w1161_img.tar" w1161_img.tar
put_one "$LEG96" w1143_leg_shot96.out

bash "$D/kmod/w999_runcap.sh" kmod/w1161_remote.sh "$N" "$T" >"$EV/${N}.wrap.log" 2>&1
WRAP_RC=$?
echo "run rc=$WRAP_RC"
OUT="$EV/${N}.txt"
[ -f "$OUT" ] || { echo "!! 没有产物 $OUT ⇒ 判失败"; exit 1; }

g1() { grep -ao "^MD5_$1=[0-9a-f]\{32\}" "$OUT" | head -1 | cut -d= -f2; }
for pair in "w1161_gate.h=$L_GATE" "w1159_wire.h=$L_WIRE" "w1151_core.h=$L_CORE" "w1155_record.h=$L_REC" "w1161_main.c=$L_MAIN" "w1161_supercall.h=$L_SUP" "w1161_app_profile.h=$L_APF" "w1161_img.tar=$L_IMGTAR" "w1143_leg_shot96.out=$L_LEG96"; do
  k=${pair%%=*}; want=${pair#*=}; got=$(g1 "$k")
  [ "$got" = "$want" ] && echo "  [ok] 两端同 md5：$k" || { echo "  [BAD] $k 远端=${got:-空} 本地=$want"; BAD=1; }
done
grep -aq '^IMG_FILES=2$' "$OUT" || { echo "  [BAD] 远端不是两张图"; BAD=1; }
grep -aq "^IMG pol.before bytes=$(wc -c <"$IMGDIR/pol.before" | tr -dc '0-9')" "$OUT" || { echo "  [BAD] 远端 pol.before 的字节数与本地不同"; BAD=1; }
for k in post_pre_len post_pre_sum post_post_len post_post_sum; do
  grep -aq "^LEG_$k=1$" "$OUT" || { echo "  [BAD] 腿证件里键 $k 数到不是 1(证件形状变了？)"; BAD=1; }
done
grep -aq '^HOST_MAKE_RC=0$' "$OUT" || { echo "  [BAD] 宿主编译没通过"; BAD=1; }
grep -aq '^DIAG_ERR=0 DIAG_WARN=0$' "$OUT" || { echo "  [BAD] 宿主编译有诊断"; BAD=1; }
grep -aq '^RUN_RC=0$' "$OUT" || { echo "  [BAD] 正跑没绿"; BAD=1; }
NOKL=$(grep -ac '^  okline: ' "$OUT")
[ "$NOKL" -ge 2 ] || { echo "  [BAD] 抄进证件的 okline 只有 $NOKL 条(至少 T1/T6 两条要说出了证人是谁)"; BAD=1; }
grep -a '^  okline: ' "$OUT" | sed 's/^/  /'
grep -aq 'SUM asserts=[0-9]\{1,6\} fails=0$' "$OUT" || { echo "  [BAD] SUM 那行不是 fails=0"; BAD=1; }
grep -aq 'VERDICT=w1161_pass' "$OUT" || { echo "  [BAD] 自测 VERDICT 不是 pass"; BAD=1; }
N5=$(grep -ac '^MUT_.*=CAUGHT' "$OUT")
[ "$N5" = 5 ] || { echo "  [BAD] 五条变异只抓到 $N5 条(应当 5：orderless/smallbound/capbound/armdrop/magicmem)"; BAD=1; }
grep -a '^MUT_' "$OUT" | sed 's/^/  /'
grep -aqE '^REVERT_RC=0([ (]|$)' "$OUT" || { echo "  [BAD] 还原后没跑绿 ⇒ 变异可能留在了件里"; BAD=1; }
grep -aq '^VERDICT=ok' "$OUT" || { echo "  [BAD] 远端总判据没到 ok"; BAD=1; }

echo "=== 结论 ==="
if [ "$BAD" = 0 ]; then
  echo "VERDICT=w1161_green #238 部件③装载门的**纯判定**判正(真图两把指纹＋逐闸扳红＋次序逐对＋老魔数那条变异被抓)；货未动；设备一发没打"
else
  echo "VERDICT=w1161_red 上面每条 [BAD] 都是**仪器或输入面**的红，不是被测"
fi
exit 0
