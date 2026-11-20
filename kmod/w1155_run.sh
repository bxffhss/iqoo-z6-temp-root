#!/bin/bash
# w1155_run.sh —— 本地包装(0 枪)：把记录层三件＋夹具＋**第 97 发那份腿证件**put 上构建机，
#   跑 `w1155_remote.sh`(宿主编译＋自测＋四条变异)，两端 md5 逐件对表，判决只认远端印出来的行。
# ★为什么把腿证件一起送上去：C8 那把尺的证人不是我再抄一遍期望，而是**设备那一发内核自己印的
#   rec_stmts**；记录层要在跨机这一格上也对得上，才有资格进出货 ko。
# 用法：HRMT_CLI=hermes-remote1/cli.py bash kmod/w1155_run.sh [证件名] [超时秒]
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-w1155_host_v1}"
T="${2:-500}"
REC="$D/kmod/w1155_sepol_record.h"
CORE="$D/kmod/w1151_sepolicy_core.h"
MAIN="$D/kmod/w1155_host_selftest.c"
FIX="$D/kmod/w1152_fixtures"
LEG="$D/kmod/w103_evidence/w1153_leg_shot97.out"
EV="$D/kmod/w103_evidence"

for f in "$REC" "$CORE" "$MAIN" "$LEG"; do
  [ -s "$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
[ -s "$FIX/expect.txt" ] || { echo "!! 期望表不在(先跑 python kmod/w1152_sepd_fixtures.py)"; exit 1; }
L_REC=$(md5sum "$REC" | cut -d' ' -f1); L_CORE=$(md5sum "$CORE" | cut -d' ' -f1)
L_MAIN=$(md5sum "$MAIN" | cut -d' ' -f1); L_LEG=$(md5sum "$LEG" | cut -d' ' -f1)
echo "本地：记录层=$L_REC 核心=$L_CORE 自测源=$L_MAIN 腿证件=$L_LEG"

CLI="${HRMT_CLI:-$D/hermes-remote/cli.py}"; CFG="${HRMT_CONFIG:-$(dirname "$CLI")/config.json}"
{ [ -f "$CLI" ] && [ -f "$CFG" ]; } || { echo "!! 端点不对：CLI=$CLI CFG=$CFG"; exit 1; }
TARLIST=$(cd "$FIX" && ls *.bin expect.txt | tr '\n' ' ')
tar -C "$FIX" -cf "$EV/w1155_fix.tar" $TARLIST || { echo "!! tar 失败"; exit 1; }
echo "夹具打包：$(wc -c <"$EV/w1155_fix.tar" | tr -dc '0-9') 字节 md5=$(md5sum "$EV/w1155_fix.tar" | cut -d' ' -f1)"

put_one() {
  local src="$1" dst="$2" out rc
  out=$(PYTHONUTF8=1 python "$CLI" --config "$CFG" put "$src" "$dst" 2>&1); rc=$?
  echo "  put $dst rc=$rc (真证人＝下面两端 md5 那一格)"
  [ "$rc" = 0 ] || { echo "!! put $dst 失败 ⇒ 停"; exit 1; }
}
put_one "$CORE" w1151_core.h
put_one "$REC"  w1155_record.h
put_one "$MAIN" w1155_main.c
put_one "$EV/w1155_fix.tar" w1155_fix.tar
put_one "$LEG" w1153_leg_shot97.out

bash "$D/kmod/w999_runcap.sh" kmod/w1155_remote.sh "$N" "$T" > "$EV/${N}.wrap.log" 2>&1
echo "run rc=$?"
OUT="$EV/${N}.txt"
[ -f "$OUT" ] || { echo "!! 没有产物 $OUT ⇒ 判失败"; exit 1; }

BAD=0
g1() { grep -ao "^MD5_$1=[0-9a-f]\{32\}" "$OUT" | head -1 | cut -d= -f2; }
for pair in "w1151_core.h=$L_CORE" "w1155_record.h=$L_REC" "w1155_main.c=$L_MAIN" "w1153_leg_shot97.out=$L_LEG"; do
  k=${pair%%=*}; want=${pair#*=}; got=$(g1 "$k")
  [ "$got" = "$want" ] && echo "[ok] 两端同 md5：$k" || { echo "[BAD] $k 远端=${got:-空} 本地=$want"; BAD=1; }
done
grep -aq '^FIXTURES_BINS=11$' "$OUT" || { echo "[BAD] 远端夹具不是 11 件"; BAD=1; }
grep -aq '^TBL_LINES=12$' "$OUT"     || { echo "[BAD] 远端表不是 12 行(与夹具不同源?)"; BAD=1; }
grep -aq '^LEG_CASES=12$' "$OUT"     || { echo "[BAD] 腿证件不是 12 格(C8 的证人少了)"; BAD=1; }
grep -aq '^HOST_MAKE_RC=0$' "$OUT"   || { echo "[BAD] 宿主编译没通过"; BAD=1; }
grep -aq '^DIAG_ERR=0 DIAG_WARN=0$' "$OUT" || { echo "[BAD] 宿主编译有诊断(含 -Werror ⇒ 不该过)"; BAD=1; }
grep -aq '^RUN_RC=0$' "$OUT"         || { echo "[BAD] 正跑没绿"; BAD=1; }
grep -aq 'SUM asserts=[0-9]\{1,6\} fails=0$' "$OUT" || { echo "[BAD] 自测的 SUM 那行不是 fails=0"; BAD=1; }
grep -aq 'VERDICT=w1155_pass' "$OUT" || { echo "[BAD] 自测 VERDICT 不是 pass"; BAD=1; }
N4=$(grep -ac '^MUT_.*=CAUGHT' "$OUT")
[ "$N4" = 4 ] || { echo "[BAD] 四条变异里只抓到 $N4 条(应当 4：whygate/rctable/applied/argmax)"; BAD=1; }
grep -a '^MUT_' "$OUT" | sed 's/^/  /'
grep -aqE '^REVERT_RC=0([ (]|$)' "$OUT" || { echo "[BAD] 还原后没跑绿 ⇒ 变异可能留在了件里"; BAD=1; }
grep -aq '^VERDICT=ok' "$OUT"   || { echo "[BAD] 远端总判据没到 ok"; BAD=1; }
echo "  自测行数：$(grep -a '^OK_LINES=' "$OUT")"

echo "=== 结论 ==="
if [ "$BAD" = 0 ]; then
  echo "VERDICT=w1155_green 记录层在 x86 宿主判正(且 STMT 行数＝第 97 发设备上内核自己印的那份)"
else
  echo "VERDICT=w1155_red 上面每条 [BAD] 都是**仪器或输入面**的红，不是被测；先修前置再谈上机"
fi
exit 0
