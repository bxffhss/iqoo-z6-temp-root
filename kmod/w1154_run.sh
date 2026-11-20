#!/bin/bash
# w1154 本地包装(0 枪)：把"上机那份核心"拿到构建机的 x86 宿主上读同一批夹具字节，
# 再把**三方**摆在一起对表：设备腿读数 / 宿主同码读数 / Python 期望表。
# 为什么要三方：第 97 发那格 bad_len(设备 max_arg=5、表=0)光看"设备 vs 表"分不出性质——
#   表是我自己写的模型，不是被测。同一份 C 码在两种机器上读同一批字节，谁错一目了然。
# 用法：HRMT_CLI=hermes-remote1/cli.py bash kmod/w1154_run.sh [证件名] [超时秒]
#   LEG_OUT=<腿件>(默认 kmod/w103_evidence/w1153_leg_shot97.out)
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-w1154_host_v1}"
T="${2:-400}"
FIXDIR="$D/kmod/w1152_fixtures"
MAIN="$D/kmod/w1154_host_probe.c"
CORE="$D/kmod/w1151_sepolicy_core.h"
TBL="$FIXDIR/expect.txt"
LEG_OUT="${LEG_OUT:-$D/kmod/w103_evidence/w1153_leg_shot97.out}"
EV="$D/kmod/w103_evidence"

for f in "$MAIN" "$CORE" "$TBL" "$LEG_OUT"; do
  [ -s "$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
L_MAIN=$(md5sum "$MAIN" | cut -d' ' -f1); L_CORE=$(md5sum "$CORE" | cut -d' ' -f1)
echo "本地：核心=$L_CORE 宿主探针源=$L_MAIN"

CLI="${HRMT_CLI:-$D/hermes-remote/cli.py}"; CFG="${HRMT_CONFIG:-$(dirname "$CLI")/config.json}"
{ [ -f "$CLI" ] && [ -f "$CFG" ]; } || { echo "!! 端点不对：CLI=$CLI CFG=$CFG"; exit 1; }
TARLIST=$(cd "$FIXDIR" && ls *.bin expect.txt | tr '\n' ' ')
tar -C "$FIXDIR" -cf "$EV/w1154_fix.tar" $TARLIST || { echo "!! tar 失败"; exit 1; }
echo "夹具打包：$(wc -c <"$EV/w1154_fix.tar" | tr -dc '0-9') 字节 md5=$(md5sum "$EV/w1154_fix.tar" | cut -d' ' -f1)"

put_one() {
  local src="$1" dst="$2" out rc
  out=$(PYTHONUTF8=1 python "$CLI" --config "$CFG" put "$src" "$dst" 2>&1); rc=$?
  echo "  put $dst rc=$rc (真证人＝下面两端 md5 那一格)"
  [ "$rc" = 0 ] || { echo "!! put $dst 失败 ⇒ 停"; exit 1; }
}
put_one "$CORE" "w1154_core.h"
put_one "$MAIN" "w1154_main.c"
put_one "$EV/w1154_fix.tar" "w1154_fix.tar"

bash "$D/kmod/w999_runcap.sh" kmod/w1154_remote.sh "$N" "$T" > "$EV/${N}.wrap.log" 2>&1
echo "run rc=$?"
OUT="$EV/${N}.txt"
[ -f "$OUT" ] || { echo "!! 没有产物 $OUT ⇒ 判失败"; exit 1; }

fld() { sed -n "s/.*[ =]$1=\([^ ]*\).*/\1/p" <<<"$2" | head -1; }
BAD=0
R_CORE=$(grep -ao '^MD5_w1154_core.h=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
R_MAIN=$(grep -ao '^MD5_w1154_main.c=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
[ "$R_CORE" = "$L_CORE" ] && echo "[ok] 核心两端一致(上机那份＝宿主这份)" || { echo "[BAD] 核心不一致：本地 $L_CORE 远端 ${R_CORE:-空}"; BAD=1; }
[ "$R_MAIN" = "$L_MAIN" ] && echo "[ok] 宿主探针源两端一致" || { echo "[BAD] 探针源不一致：本地 $L_MAIN 远端 ${R_MAIN:-空}"; BAD=1; }
grep -aq '^HOST_MAKE_RC=0$' "$OUT" || { echo "[BAD] 宿主编译没过"; BAD=1; }
grep -aq '^DIAG_ERR=0 DIAG_WARN=0$' "$OUT" || { echo "[BAD] 宿主编译有诊断(含 -Werror)"; BAD=1; }
grep -aq '^PROBE_LINES=12 MISSING=0' "$OUT" || { echo "[BAD] 宿主没跑满 12 格(或有 MISSING)"; BAD=1; }
grep -aq '^FIXTURES_BINS=11' "$OUT" || { echo "[BAD] 远端夹具不是 11 件"; BAD=1; }
grep -aq '^VERDICT=ok' "$OUT" || { echo "[BAD] 远端判据没到 ok"; BAD=1; }

# ★逐件 md5：远端那 11 行 `FIXMD5 <md5> <名>` 必须与本地逐字相同(包在路上没变味)
RN=$(grep -ac '^FIXMD5 ' "$OUT")
MDIFF=0
while read -r h fn; do
  grep -q "^FIXMD5 $h $fn\$" "$OUT" || { echo "  [x] 远端 $fn 与本地 md5 不同(本地 $h)"; MDIFF=$((MDIFF+1)); }
done < <(cd "$FIXDIR" && md5sum *.bin)
LN=$(cd "$FIXDIR" && ls *.bin | wc -l | tr -dc '0-9')
if [ "$RN" = "$LN" ] && [ "$MDIFF" = 0 ]; then echo "[ok] 夹具 $LN 件两端逐件同 md5"
else echo "[BAD] 夹具两端对不上(远端行=$RN 本地件=$LN 不符数=$MDIFF)"; BAD=1; fi

echo; echo "=== 三方对表：设备(aarch64 内核) / 宿主(x86，同一份 C 码) / 期望表(Python 模型) ==="
printf '%-10s %-22s | %-22s | %s\n' CASE "设备 why/n/at/maxarg/lm" "宿主 同五项" "表 同五项"
DH=0; DT=0; HT=0; DHT=""
while read -r name; do
  dline=$(grep -m1 "^CASE $name " "$LEG_OUT")
  hline=$(grep -m1 "^PROBE $name " "$OUT")
  tline=$(grep -m1 "^$name " "$TBL")
  if [ -z "$dline" ] || [ -z "$hline" ] || [ -z "$tline" ]; then
    echo "[BAD] $name 三方有一方没读数(设备[$dline] 宿主[$hline])"; BAD=1; continue
  fi
  dd=""; hh=""; tt=""; dif=""
  for k in why n bad_at max_arg lenmatch; do
    dv=$(fld "$k" "$dline"); hv=$(fld "$k" "$hline"); tv=$(fld "$k" "$tline")
    dd="$dd$dv/"; hh="$hh$hv/"; tt="$tt$tv/"
    [ "$dv" = "$hv" ] || { dif="$dif $k(设$dv≠宿$hv)"; }
  done
  dfv=$(fld in_fnv "$dline"); hfv=$(fld fnv "$hline"); tfv=$(fld fnv "$tline")
  [ "$dfv" = "$hfv" ] || dif="$dif fnv"
  if [ -n "$dif" ]; then DH=$((DH+1)); DHT="$DHT $name[$dif]"; fi
  [ "$dd" = "$tt" ] || DT=$((DT+1))
  [ "$hh" = "$tt" ] || HT=$((HT+1))
  printf '%-10s %-22s | %-22s | %-22s %s\n' "$name" "${dd%/}" "${hh%/}" "${tt%/}" "$dif"
done < <(sed -n 's/^\([a-z0-9_]*\) file=.*/\1/p' "$TBL")

echo "DIFF：设备≠宿主=$DH ｜ 设备≠表=$DT ｜ 宿主≠表=$HT   (每格六把：why/n/bad_at/max_arg/lenmatch/fnv)"
[ -n "$DHT" ] && echo "  设备≠宿主的格：$DHT"
if [ "$BAD" = 0 ] && [ "$DH" = 0 ]; then
  echo "VERDICT=w1154_arch_same  跨架构一致：同一份核心在 aarch64 内核与 x86 宿主上读同一批字节，六把读数全同"
  [ "$DT" = 0 ] && echo "  期望表也全对" || echo "  期望表另有 $DT 处与两端都不同 ⇒ 那是 Python 模型红(仪器)，不是被测"
elif [ "$BAD" = 0 ]; then
  echo "VERDICT=w1154_ARCHDIFF  设备与宿主真的不同 ⇒ 这是发现，要归因，不许圆场"
else
  echo "VERDICT=w1154_FAIL(仪器：身份/覆盖没齐)"
fi
exit 0
