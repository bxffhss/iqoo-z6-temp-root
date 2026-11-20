#!/bin/bash
# 本地包装：把「主源 + 桩」put 到远端，跑构建脚本，再把两端 md5 比一遍。
# 为什么把比较放在本地：期望值不写死在远端脚本里 ⇒ 改了源不会留下"注册值滞后"的假账(§6.459 那类)。
# 用法：bash kmod/w985_run.sh <仓库里的主源.c> <产物证件名> [超时秒]
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="${1:?要主源，例如 kmod/w985_probe.c 或 kmod/w986_polround.c}"
N="${2:?要证件名}"
T="${3:-600}"
[ -f "$D/$MAIN" ] || { echo "!! 主源不在仓库：$MAIN"; exit 1; }

L_MAIN=$(md5sum "$D/$MAIN" | cut -d' ' -f1)
L_GLUE=$(md5sum "$D/kmod/w987_ss_glue.c" | cut -d' ' -f1)
# ★端点可换(与 w999_runcap.sh 同一套 knobs)：默认旧机，HRMT_CLI=hermes-remote1/cli.py 就整机切到新机。
CLI="${HRMT_CLI:-$D/hermes-remote/cli.py}"
CFG="${HRMT_CONFIG:-$(dirname "$CLI")/config.json}"
[ -f "$CLI" ] || { echo "!! 客户端不在：$CLI"; exit 1; }
[ -f "$CFG" ] || { echo "!! 端点配置不在：$CFG"; exit 1; }
echo "端点 CLI=$CLI CONFIG=$CFG"
echo "本地主源 $MAIN md5=$L_MAIN"
echo "本地桩   w987_ss_glue.c md5=$L_GLUE"

put() {
  local SRC="$1" DST="$2" out rc
  out=$(PYTHONUTF8=1 python "$CLI" --config "$CFG" put "$SRC" "$DST" 2>&1)
  rc=$?
  printf '%s' "$out" | tr -d '\r' | tail -1
  if [ "$rc" -ne 0 ]; then
    echo "!! put $DST 失败 rc=$rc ⇒ 停(不要编一份来源不明的件)"
    exit 1
  fi
}
put "$D/$MAIN" w985_main.c
put "$D/kmod/w987_ss_glue.c" w987_ss_glue.c

# ★第 84 发那一格的开关(细节见 w985_ssport_build.sh 的 1c)：`SUBSTEP=on` ⇒ 把打补丁件铺过去，并在远端写一张
#   内容为 on/off 的"纸片"当开关。★为什么不是"文件在＝on"：那要一次远端 `rm`，漏删就**静默换形状**(最坏的那种失效)；
#   也不是环境变量：`w999_runcap.sh` 走 `cli.py exec --file`，env 不过去。构建证件里会现印 `SUBSTEP=<现读值>`，
#   下面这条复证要求"印出来的＝我要的"，`on` 时还必须有 `PATCH_VERDICT=ok` ⇒ 我点没点、打上没打上，两边都不许猜。
SUBSTEP="${SUBSTEP:-off}"
case "$SUBSTEP" in on|off) : ;; *) echo "[x] SUBSTEP 只认 on/off(给的是[$SUBSTEP]) ⇒ 停"; exit 2 ;; esac
[ "$SUBSTEP" = on ] && put "$D/kmod/w1085_substep_patch.py" w1085_substep_patch.py
printf '%s\n' "$SUBSTEP" > "$D/kmod/w103_evidence/w985_substep_state.txt"
put "$D/kmod/w103_evidence/w985_substep_state.txt" SUBSTEP

bash "$D/kmod/w999_runcap.sh" kmod/w985_ssport_build.sh "$N" "$T" \
  > "$D/kmod/w103_evidence/w985_wrap.log" 2>&1
RUN_RC=$?
OUT="$D/kmod/w103_evidence/$N.txt"
echo "run rc=$RUN_RC (0＝远端脚本跑完，不代表编译过——编译结论看下面的 MAKE_RC)"
[ -f "$OUT" ] || { echo "!! 没有产物 $OUT ⇒ 判失败，不看第二眼"; exit 1; }

R_MAIN=$(grep -o '^MAIN_MD5=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
R_GLUE=$(grep -o '^GLUE_MD5=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
BAD=0
for pair in "主源:$L_MAIN:$R_MAIN" "桩:$L_GLUE:$R_GLUE"; do
  name=${pair%%:*}; rest=${pair#*:}; l=${rest%%:*}; r=${rest#*:}
  if [ -z "$r" ]; then echo "[BAD] 远端没报 $name 的 md5 ⇒ 这格算未测，不许当通过"; BAD=1;
  elif [ "$r" != "$l" ]; then echo "[BAD] $name 两端不一致：本地 $l / 远端 $r ⇒ 停"; BAD=1;
  else echo "[ok] $name 两端一致($l)"; fi
done
#   ★开关也要复证(不是"我点了 on 就算 on")：证件里那行 `SUBSTEP=` 必须＝我要的值；on 时还必须有 `PATCH_VERDICT=ok`。
R_SUB=$(grep -ao '^SUBSTEP=[a-z]*' "$OUT" | head -1 | cut -d= -f2)
if [ "$R_SUB" != "$SUBSTEP" ]; then
  echo "[BAD] 远端证件里 SUBSTEP=[$R_SUB] ≠ 我要的[$SUBSTEP] ⇒ 这份件不是我点的那一格，别拿它上机"; BAD=1
fi
if [ "$SUBSTEP" = on ]; then
  grep -aq '^PATCH_VERDICT=ok' "$OUT" || { echo "[BAD] 点了 on 但证件里没有 PATCH_VERDICT=ok ⇒ 停"; BAD=1; }
  for f in policydb.c avtab.c; do
    v=$(grep -ao "^PATCHED_MD5_$f=[0-9a-f]*" "$OUT" | head -1 | cut -d= -f2)
    [ -n "$v" ] && echo "[ok] 打过补丁的 $f 远端 md5=$v" || { echo "[BAD] 没报 PATCHED_MD5_$f ⇒ 停"; BAD=1; }
  done
fi
[ "$BAD" -eq 0 ] || exit 1
sed -n '1,90p' "$OUT"
