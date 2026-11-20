#!/bin/bash
# 本地包装(#237 B′)：把主源 put 到构建机 → 跑远端构建脚本 → **两端 md5 复证** →(FETCH=1)把 .ko 取回仓库再比一次。
# 为什么比较放在本地：期望值不写死在远端脚本里 ⇒ 改了源不会留下"注册值滞后"的假账(§6.459 那类)。
# 用法：HRMT_CLI=hermes-remote1/cli.py bash kmod/w1141_run.sh [证件名] [超时秒]
#   FETCH=1 ⇒ 顺带把产物拉回 kmod/w103_evidence/ 并比 md5(默认不拉：构建红的时候没必要搬件)
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-w1141_build_v1}"
T="${2:-600}"
MAIN="$D/kmod/w1140_polload.c"
[ -f "$MAIN" ] || { echo "!! 主源不在仓库：$MAIN"; exit 1; }
L_MAIN=$(md5sum "$MAIN" | cut -d' ' -f1)

# ★端点必须可换(10-28 迁机那一手)：写死旧路径会**静默把件传到另一台机上**，回执照样绿但灯不是这台机的。
CLI="${HRMT_CLI:-$D/hermes-remote/cli.py}"
CFG="${HRMT_CONFIG:-$(dirname "$CLI")/config.json}"
[ -f "$CLI" ] || { echo "!! 客户端不在：$CLI"; exit 1; }
[ -f "$CFG" ] || { echo "!! 端点配置不在：$CFG"; exit 1; }
echo "端点 CLI=$CLI CONFIG=$CFG"
echo "本地主源 kmod/w1140_polload.c md5=$L_MAIN"

out=$(PYTHONUTF8=1 python "$CLI" --config "$CFG" put "$MAIN" w1141_main.c 2>&1)
rc=$?
printf '%s' "$out" | tr -d '\r' | tail -1
if [ "$rc" -ne 0 ]; then
  echo "!! put 主源失败 rc=$rc ⇒ 停(不要编一份来源不明的件)"
  exit 1
fi

bash "$D/kmod/w999_runcap.sh" kmod/w1141_polload_build.sh "$N" "$T" \
  > "$D/kmod/w103_evidence/${N}.wrap.log" 2>&1
RUN_RC=$?
OUT="$D/kmod/w103_evidence/${N}.txt"
echo "run rc=$RUN_RC (0＝远端脚本跑完，不代表编过——编译结论看证件里的 MAKE_RC/DIAG_*/VERDICT)"
[ -f "$OUT" ] || { echo "!! 没有产物 $OUT ⇒ 判失败，不看第二眼"; exit 1; }

BAD=0
R_MAIN=$(grep -ao '^MAIN_MD5=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
if [ -z "$R_MAIN" ]; then
  echo "[BAD] 远端没报主源 md5 ⇒ 这格算未测，不许当通过"; BAD=1
elif [ "$R_MAIN" != "$L_MAIN" ]; then
  echo "[BAD] 主源两端不一致：本地 $L_MAIN / 远端 $R_MAIN ⇒ 停(陈件！)"; BAD=1
else
  echo "[ok] 主源两端一致($L_MAIN)"
fi
# 出处三件：桩与两份头。★这里只要求"证件报了 32 位十六进制"——桩来自出货 ko 那棵树，
#   它的现值由 DELIVERY 登记，不在本仓库里，所以本地比不了；不报＝这格未测＝不许过。
for k in STUB_MD5 HDR_SECURITY_MD5 HDR_FLASK_MD5; do
  v=$(grep -ao "^$k=[0-9a-f]\{32\}" "$OUT" | head -1 | cut -d= -f2)
  if [ -n "$v" ]; then echo "[ok] 出处 $k=$v"; else echo "[BAD] 证件里没报 $k ⇒ 出处追不到，不许过"; BAD=1; fi
done
# ★键值行在证件里是缩进打印的(`  CFI_STUB=1`)，锚行首会把绿的说成红的——这把我自己踩了一次。
grep -aqE '^[[:space:]]*CFI_STUB=1$' "$OUT" || { echo "[BAD] 证件里没有 CFI_STUB=1 ⇒ 停(§6.484)"; BAD=1; }
grep -aq '^VERDICT=ok' "$OUT" || { echo "[BAD] 远端判据没到 VERDICT=ok ⇒ 这个件不许派上机"; BAD=1; }
[ "$BAD" -eq 0 ] || { echo "---- 证件全文 ----"; cat "$OUT"; exit 1; }

if [ "${FETCH:-0}" = 1 ]; then
  R_KO=$(grep -ao '^KO_COPY_MD5=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
  [ -n "$R_KO" ] || { echo "[BAD] 证件没报 KO_COPY_MD5 ⇒ 不拉件"; exit 1; }
  L_KO="$D/kmod/w103_evidence/z6polload_v1.ko"
  PYTHONUTF8=1 python "$CLI" --config "$CFG" get w1141_z6polload.ko "$L_KO" >/dev/null 2>&1 \
    || { echo "!! get 失败 ⇒ 停"; exit 1; }
  [ -s "$L_KO" ] || { echo "!! 拉回来是空的(★远端参数要给相对名，绝对名会给 0 字节)⇒ 停"; exit 1; }
  G_KO=$(md5sum "$L_KO" | cut -d' ' -f1)
  if [ "$G_KO" != "$R_KO" ]; then
    echo "[BAD] 产物两端不一致：远端 $R_KO / 本地 $G_KO ⇒ 停"; exit 1
  fi
  echo "[ok] 产物已进仓库：kmod/w103_evidence/z6polload_v1.ko md5=$G_KO"
fi
sed -n '1,120p' "$OUT"
