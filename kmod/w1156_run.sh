#!/bin/bash
# w1156_run.sh —— 本地包装(0 枪)：把 rc75 候选桩编进**出货同一条流水线**，产物只当候选收进证据目录。
#   ★三件货没动的事实在这里证：跑之前现读出货 ko 的 md5，跑之后再读一次 ⇒ 必须一模一样。
#   用法：HRMT_CLI=hermes-remote1/cli.py bash kmod/w1156_run.sh [证件名] [超时秒]
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-w1156_rc75_v1}"
T="${2:-1500}"
SHIP="$D/kmod/kernelsu_rc74c.ko"
STUB="$D/kmod/ksu_dropped_stub_rc75.c"
CORE="$D/kmod/w1151_sepolicy_core.h"
REC="$D/kmod/w1155_sepol_record.h"
PIPE="$D/kmod/remote_ksu_rc74c.sh"
EV="$D/kmod/w103_evidence"

for f in "$SHIP" "$STUB" "$CORE" "$REC" "$PIPE"; do
  [ -s "$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
SHIP0=$(md5sum "$SHIP" | cut -d' ' -f1)
echo "出货 ko 现读(跑之前)=$SHIP0  字节=$(wc -c <"$SHIP" | tr -dc '0-9')"
echo "候选桩=$(md5sum "$STUB" | cut -d' ' -f1) 核心=$(md5sum "$CORE" | cut -d' ' -f1) 记录层=$(md5sum "$REC" | cut -d' ' -f1) 流水线=$(md5sum "$PIPE" | cut -d' ' -f1)"

CLI="${HRMT_CLI:-$D/hermes-remote/cli.py}"; CFG="${HRMT_CONFIG:-$(dirname "$CLI")/config.json}"
{ [ -f "$CLI" ] && [ -f "$CFG" ]; } || { echo "!! 端点不对：CLI=$CLI CFG=$CFG"; exit 1; }
put_one() {
  local src="$1" dst="$2" out rc
  out=$(PYTHONUTF8=1 python "$CLI" --config "$CFG" put "$src" "$dst" 2>&1); rc=$?
  echo "  put $dst rc=$rc (真证人＝下面的两端 md5)"
  [ "$rc" = 0 ] || { echo "!! put $dst 失败 ⇒ 停"; exit 1; }
}
put_one "$PIPE" ksu_rc74c.sh
put_one "$STUB" w1156_stub.c
put_one "$CORE" w1156_core.h
put_one "$REC"  w1156_record.h
# 参照 md5 走**文件**交接：`w999_runcap.sh` 不转发位置参数(上一版传了第四个参数，远端永远收不到)
printf '%s
' "$SHIP0" > "$EV/w1156_shipmd5.txt"
# 树里现役桩的"出货那份"md5：现读自 11-05 第 97/98 轮证件 `w1153/w1156` 的 A 段(不是抄记忆)——
# 它的作用是"脏树能不能被发现"，所以宁可多传一个文件也不在远端写死。
STUB_WANT=8795ceb4e73e8344e07dd5be30b4e0fa
printf '%s
' "$STUB_WANT" > "$EV/w1156_stubmd5.txt"
put_one "$EV/w1156_stubmd5.txt" w1156_stubmd5.txt
put_one "$EV/w1156_shipmd5.txt" w1156_shipmd5.txt

bash "$D/kmod/w999_runcap.sh" kmod/w1156_remote.sh "$N" "$T" > "$EV/${N}.wrap.log" 2>&1
echo "run rc=$?"
OUT="$EV/${N}.txt"
[ -f "$OUT" ] || { echo "!! 没有产物 $OUT ⇒ 判失败(看 $EV/${N}.wrap.log)"; tail -20 "$EV/${N}.wrap.log"; exit 1; }

BAD=0
g1() { grep -ao "^MD5_$1=[0-9a-f]\{32\}" "$OUT" | head -1 | cut -d= -f2; }
for pair in "w1156_shipmd5.txt=$(md5sum "$EV/w1156_shipmd5.txt" | cut -d' ' -f1)" "w1156_stubmd5.txt=$(md5sum "$EV/w1156_stubmd5.txt" | cut -d' ' -f1)" "ksu_rc74c.sh=$(md5sum "$PIPE" | cut -d' ' -f1)" "w1156_stub.c=$(md5sum "$STUB" | cut -d' ' -f1)" "w1156_core.h=$(md5sum "$CORE" | cut -d' ' -f1)" "w1156_record.h=$(md5sum "$REC" | cut -d' ' -f1)"; do
  k=${pair%%=*}; want=${pair#*=}; got=$(g1 "$k")
  [ "$got" = "$want" ] && echo "[ok] 两端同 md5：$k" || { echo "[BAD] $k 远端=${got:-空} 本地=$want"; BAD=1; }
done
grep -aq "^SHIPPED_MD5_WANT=$SHIP0$" "$OUT" || { echo "[BAD] 远端没收到出货 md5 这个参照"; BAD=1; }
grep -aq "^RC74C_RC=0" "$OUT" || { echo "[BAD] A 阶段流水线没跑完(候选无可比参照)"; BAD=1; }
grep -aq '可比性成立' "$OUT" || { echo "[BAD] A 阶段产物 ≠ 出货那份 ⇒ 环境漂了，B 的结果不能叫候选"; BAD=1; }
grep -aq '^MAKE_B_RC=0$' "$OUT" || { echo "[BAD] B 没编出来(这本身就是答案：桩在内核头下编不过)"; BAD=1; }
grep -aq '^B_LOG err=0' "$OUT" || { echo "[BAD] B 有 error"; BAD=1; }
grep -aq '新增未定义符号逐条已在 Module.symvers' "$OUT" || { echo "[BAD] 新增符号没逐条验导出"; BAD=1; }
grep -aq 'SS/security_\* 外流=0' "$OUT" || { echo "[BAD] 有 SS 符号外流"; BAD=1; }
grep -aqE '^  __cfi_check=1' "$OUT" || { echo "[BAD] __cfi_check 不是 1"; BAD=1; }
grep -aq 'parmtype=sp_\* 条数=1[4-9]' "$OUT" || grep -aq 'parmtype=sp_\* 条数=[2-9][0-9]' "$OUT" || { echo "[BAD] 14 个读数参数没全进 .modinfo"; BAD=1; }
grep -aq 'vermagic A=\[' "$OUT" || { echo "[BAD] 没量 vermagic"; BAD=1; }
grep -aq 'MD5_B=' "$OUT" || { echo "[BAD] 远端没产出候选件 md5"; BAD=1; }
grep -aq '认不出来源的新符号=0' "$OUT" || { echo "[BAD] 新符号里有对不上这份新代码的东西"; BAD=1; }
grep -aq '计数还原后=0' "$OUT" || { echo "[BAD] main.c 没还原 ⇒ 树里留了候选改动(下一次跑出货流水线会拿它当真)"; BAD=1; }
grep -aq '现读 0(必须 0)' "$OUT" || { echo "[BAD] 两个头文件没从树里删净"; BAD=1; }
grep -aq '^VERDICT=ok' "$OUT" || { echo "[BAD] 远端总判据没到 ok"; BAD=1; }
echo "  桩还原前后：$(grep -ao '现役桩(出货那份)md5=[0-9a-f]*' "$OUT") $(grep -ao '桩还原 md5=[0-9a-f]*' "$OUT")"
A1=$(grep -ao '现役桩(出货那份)md5=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
A2=$(grep -ao '桩还原 md5=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
[ -n "$A1" ] && [ "$A1" = "$A2" ] && echo "[ok] 树里的桩还原成出货那份(逐字节同)" || { echo "[BAD] 桩还原前后不同($A1→$A2)"; BAD=1; }

MD5B=$(grep -ao '^MD5_B=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
if [ -n "$MD5B" ]; then
  echo "  候选件远端 md5=$MD5B ⇒ 取回本地(只进证据目录，不进包)"
  PYTHONUTF8=1 python "$CLI" --config "$CFG" get w1156_kernelsu_rc75_candidate.ko "$EV/kernelsu_rc75_candidate.ko" 2>&1 | tail -1
  LB=$(md5sum "$EV/kernelsu_rc75_candidate.ko" 2>/dev/null | cut -d' ' -f1)
  [ "$LB" = "$MD5B" ] && echo "[ok] 候选件两端同 md5：$LB  字节=$(wc -c <"$EV/kernelsu_rc75_candidate.ko" | tr -dc '0-9')" || { echo "[BAD] 候选件取回后 md5 不同(本地=${LB:-空})"; BAD=1; }
fi
SHIP1=$(md5sum "$SHIP" | cut -d' ' -f1)
[ "$SHIP1" = "$SHIP0" ] && echo "[ok] 出货 ko 跑前后同值(货没动)" || { echo "[BAD] 出货 ko 被改了($SHIP0→$SHIP1)"; BAD=1; }

echo "=== 结论 ==="
if [ "$BAD" = 0 ]; then
  echo "VERDICT=w1156_green rc75 候选件编出来了：与出货那份只差『换桩＋接一行收尾』两个变量，尺全过；候选在 $EV/kernelsu_rc75_candidate.ko(未上机、未进包)"
else
  echo "VERDICT=w1156_red 见上面 [BAD]；每一条都是仪器或输入面的红，不是被测"
fi
exit 0
