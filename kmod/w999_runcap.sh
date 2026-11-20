#!/bin/bash
# 本地包装：把远端 exec 的 stdout 单独落到 kmod/w103_evidence/，避开 GBK 控制台与 JSON 噪声。
# 用法：bash kmod/w999_runcap.sh <远端脚本相对仓路径> <产物名> [超时秒]
set -u
F="${1:?需要远端脚本路径}"
N="${2:?需要产物名}"
T="${3:-300}"
D="$(cd "$(dirname "$0")/.." && pwd)"
# ★端点必须可换(10-28 迁到第二台容器换来的一手教训)：写死 `hermes-remote/cli.py` 的那些包装件，
#   换机后会**静默把件传到另一台机上**——回执照样绿，但那盏灯已经不是当前这台机的。
#   默认值保持旧路径不变(＝交付形状一字不变)，换机只要一个变量：
#     HRMT_CLI=hermes-remote1/cli.py bash kmod/w999_runcap.sh …
#   证件里现印端点，日后看产物就知道是哪台机建的，不用猜。
CLI="${HRMT_CLI:-$D/hermes-remote/cli.py}"
CFG="${HRMT_CONFIG:-$(dirname "$CLI")/config.json}"
[ -f "$CLI" ] || { echo "!! 客户端不在：$CLI"; exit 1; }
[ -f "$CFG" ] || { echo "!! 端点配置不在：$CFG"; exit 1; }
echo "端点 CLI=$CLI CONFIG=$CFG"
mkdir -p "$D/kmod/w103_evidence"
RAW="$D/kmod/w103_evidence/${N}.raw.json"
PYTHONUTF8=1 python "$CLI" --config "$CFG" exec --timeout "$T" --file "$F" > "$RAW" 2>&1
RC=$?
OUT="$D/kmod/w103_evidence/${N}.txt"
PYTHONUTF8=1 python - "$RAW" "$OUT" "$RC" <<'PY'
import json,sys
raw,out,rc=sys.argv[1:4]
try:
    d=json.load(open(raw,encoding="utf-8"))
except Exception as e:
    open(out,"w",encoding="utf-8").write(f"[本地解析失败 {e}]\n原始前 4000 字：\n"+open(raw,encoding="utf-8",errors="replace").read()[:4000])
    print("[BAD] 无法解析远端 JSON，见", out); sys.exit(1)
body=(d.get("stdout") or "")+("\n[stderr]\n"+d["stderr"] if d.get("stderr") else "")
open(out,"w",encoding="utf-8").write(body)
print(f"exit_code={d.get('exit_code')} ok={d.get('ok')} timed_out={d.get('timed_out')} cli_rc={rc} bytes={len(body)}")
print(f"产物 -> {out}")
print("---- 前 60 行 ----")
print("\n".join(body.splitlines()[:60]))
PY
