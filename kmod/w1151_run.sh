#!/bin/bash
# 本地包装(w1151/#238 部件①)：把解码核心与宿主自测 put 到构建机 ⇒ 跑 w1151_sepd_build.sh ⇒
# 两端 md5 复证(★期望值不写死在远端脚本里，改了源就不会留下"注册值滞后"的假账，§6.459 那类)。
# 用法：HRMT_CLI=hermes-remote1/cli.py bash kmod/w1151_run.sh [证件名] [超时秒]
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-w1151_host_v1}"
T="${2:-300}"
MAIN="$D/kmod/w1151_sepolicy_core.h"
SELF="$D/kmod/w1151_host_selftest.c"
PROBE="$D/kmod/w1151_sepd_probe.c"
for f in "$MAIN" "$SELF" "$PROBE"; do
  [ -f "$f" ] || { echo "!! 输入件不在仓库：$f"; exit 1; }
done
L_MAIN=$(md5sum "$MAIN" | cut -d' ' -f1)
L_SELF=$(md5sum "$SELF" | cut -d' ' -f1)
L_PROBE=$(md5sum "$PROBE" | cut -d' ' -f1)

CLI="${HRMT_CLI:-$D/hermes-remote/cli.py}"
CFG="${HRMT_CONFIG:-$(dirname "$CLI")/config.json}"
[ -f "$CLI" ] || { echo "!! 客户端不在：$CLI"; exit 1; }
[ -f "$CFG" ] || { echo "!! 端点配置不在：$CFG"; exit 1; }
echo "端点 CLI=$CLI CONFIG=$CFG"
echo "本地核心 kmod/w1151_sepolicy_core.h md5=$L_MAIN"
echo "本地自测 kmod/w1151_host_selftest.c md5=$L_SELF"
echo "本地探针 kmod/w1151_sepd_probe.c md5=$L_PROBE"

# ★别拿 `路径:名字` 拼一串再 ${pair%%:*} 拆：Windows 路径自己就带冒号(G:\...)，那样切出来是 "G"。
put_one() {
  local src="$1" dst="$2" out rc
  out=$(PYTHONUTF8=1 python "$CLI" --config "$CFG" put "$src" "$dst" 2>&1); rc=$?
  # ★回执行不指望它带信息(JSON 尾巴就是光秃秃一个 `}`)：这格的**真证人**是下面"两端 md5 一致"，
  #   这里只报 rc 与行数，别把"回执照样有字"读成"送对了文件"。
  echo "  put $dst rc=$rc (回执 $(printf '%s' "$out" | wc -l | tr -d ' ') 行；真证人＝下面两端 md5)"
  [ "$rc" -eq 0 ] || { echo "!! put $dst 失败 rc=$rc ⇒ 停(不要跑一份说不清来源的自测)"; exit 1; }
}
put_one "$MAIN" "w1151_sepolicy_core.h"
put_one "$SELF" "w1151_host_selftest.c"
put_one "$PROBE" "w1151_sepd_probe.c"

bash "$D/kmod/w999_runcap.sh" kmod/w1151_sepd_build.sh "$N" "$T" \
  > "$D/kmod/w103_evidence/${N}.wrap.log" 2>&1
RUN_RC=$?
OUT="$D/kmod/w103_evidence/${N}.txt"
echo "run rc=$RUN_RC (0＝远端脚本跑完；结论看证件里的 HOST_MAKE_RC/DIAG_*/MUT_*/VERDICT)"
[ -f "$OUT" ] || { echo "!! 没有产物 $OUT ⇒ 判失败，不看第二眼"; exit 1; }

BAD=0
R_MAIN=$(grep -ao '^MD5_w1151_sepolicy_core.h=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
R_SELF=$(grep -ao '^MD5_w1151_host_selftest.c=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
R_PROBE=$(grep -ao '^PROBE_MD5=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
R_KOCORE=$(grep -ao '^CORE_MD5_KO_SIDE=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
for k in "$L_MAIN|$R_MAIN|核心(宿主那份)" "$L_SELF|$R_SELF|自测" "$L_PROBE|$R_PROBE|探针主源"; do
  l=${k%%|*}; r=${k#*|}; r=${r%%|*}; tag=${k##*|}
  if [ -z "$r" ]; then echo "[BAD] 证件没报 $tag 的 md5 ⇒ 这格未测，不许当通过"; BAD=1
  elif [ "$l" != "$r" ]; then echo "[BAD] $tag 两端不一致：本地 $l / 远端 $r ⇒ 停(陈件！)"; BAD=1
  else echo "[ok] $tag 两端一致($l)"; fi
done
# ★"上机那份核心＝刚验过那份"这条，远端脚本自己也比了一次；这里再独立比一次(本地值对本地值)
if [ -n "$R_KOCORE" ] && [ "$R_KOCORE" = "$L_MAIN" ]; then
  echo "[ok] aarch64 那一步用的核心与本地这份同一个($R_KOCORE)"
else
  echo "[BAD] 证件没报或报的不是同一份核心：KO_SIDE=${R_KOCORE:-空} 本地=$L_MAIN"; BAD=1
fi
grep -aq '^HOST_MAKE_RC=0$' "$OUT" || { echo "[BAD] 宿主编译没到 HOST_MAKE_RC=0"; BAD=1; }
grep -aq '^DIAG_ERR=0 DIAG_WARN=0' "$OUT" || { echo "[BAD] 宿主编译诊断非零(带 warning 的自测不算尺)"; BAD=1; }
grep -aq '^RUN_RC=0$' "$OUT" || { echo "[BAD] 正件跑出来非 0 ⇒ 判负"; BAD=1; }
grep -aq '^GOOD_OK=1$' "$OUT" || { echo "[BAD] GOOD_OK 不等于 1"; BAD=1; }
for m in subcmd argmax laternul argc6; do
  v=$(grep -ao "^MUT_$m=[A-Z]*" "$OUT" | head -1 | cut -d= -f2)
  if [ "$v" = "CAUGHT" ]; then echo "[ok] 变异 $m 被抓"
  else echo "[BAD] 变异 $m 状态=$v(要 CAUGHT；NOOP/BUILDFAIL/ESCAPED 都说明那把尺没人护)"; BAD=1; fi
done
grep -aq '^HOST_VERDICT=ok' "$OUT" || { echo "[BAD] 宿主侧没先绿就去编件 ⇒ 停"; BAD=1; }
grep -aq '^KO_MAKE_RC=0$' "$OUT" || { echo "[BAD] aarch64 编件没到 KO_MAKE_RC=0"; BAD=1; }
grep -aq '^KDIAG_ERR=0 KDIAG_WARN=0 KDIAG_IMPLICIT=0' "$OUT" || { echo "[BAD] 件侧诊断非零"; BAD=1; }
# ★键值行在证件里可能**缩进**、也可能与下一条**同行**(远端那支把 MODNAME/VERMAGIC 印在同一行)。
#   锚 `^…$` 会把绿的说成红的(这一把我自己踩了两次)⇒ 用"键在行首或空格后、值后面是空格或行尾"的边界式。
grep -aqE '(^|[[:space:]])CFI_STUB=1([[:space:]]|$)' "$OUT" || { echo "[BAD] 件里没有恰 1 个 __cfi_check ⇒ 不许上机(§6.484)"; BAD=1; }
grep -aqE '(^|[[:space:]])MODNAME=z6sepdec([[:space:]]|$)' "$OUT" || { echo "[BAD] 件名不是 z6sepdec"; BAD=1; }
grep -aqE '(^|[[:space:]])VERMAGIC=\[5\.4\.281-qgki-' "$OUT" || { echo "[BAD] vermagic 不是设备那一号"; BAD=1; }
R_KO=$(grep -ao '^KO_COPY_MD5=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
[ -n "$R_KO" ] || { echo "[BAD] 证件没报 KO_COPY_MD5 ⇒ 件没落到能取的地方"; BAD=1; }
grep -aq '^VERDICT=ok' "$OUT" || { echo "[BAD] 远端判据没到 VERDICT=ok"; BAD=1; }
[ "$BAD" -eq 0 ] || { echo "---- 证件全文 ----"; cat "$OUT"; exit 1; }

if [ "${FETCH:-0}" = 1 ]; then
  [ -n "$R_KO" ] || { echo "!! 没有 KO_COPY_MD5 ⇒ 不拉件"; exit 1; }
  L_KO="$D/kmod/w103_evidence/z6sepdec_v1.ko"
  PYTHONUTF8=1 python "$CLI" --config "$CFG" get w1151_z6sepdec.ko "$L_KO" >/dev/null 2>&1 \
    || { echo "!! get 失败(★远端参数要给相对名)"; exit 1; }
  [ -s "$L_KO" ] || { echo "!! 拉回来是空的(远端绝对名会给 0 字节)⇒ 停"; exit 1; }
  G_KO=$(md5sum "$L_KO" | cut -d' ' -f1)
  [ "$G_KO" = "$R_KO" ] || { echo "[BAD] 产物两端不一致：远端 $R_KO / 本地 $G_KO ⇒ 停"; exit 1; }
  echo "[ok] 产物已进仓库：kmod/w103_evidence/z6sepdec_v1.ko md5=$G_KO"
fi
cat "$OUT"
echo "W1151_RUN=ok"
