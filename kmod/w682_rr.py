#!/usr/bin/env python3
# w682_rr.py —— 在构建机(<BUILD_HOST>)上跑一条 bash 并把 stdout **原样**打到本机终端。
#   为什么要有它：以前 `cli.py exec` 直接管道给 python 解 JSON 会被 cli 自己的 BOM/换行坑到(这一发就是)，
#   而且远端中文输出在 GBK 控制台会 UnicodeEncodeError(看着像远端失败，其实早跑完)。⇒ 落一份 json 再解，
#   并且解码用 unicode_escape(远端是 \n 转义的)，输出走 errors='replace'。
#   用法：PYTHONUTF8=1 python kmod/w682_rr.py '<一条 bash>'   (超时可用 W682_T=秒 覆盖，默认 280)
#   ★端点：默认旧机；换机给 HRMT_CLI=hermes-remote1/cli.py（与 w999_runcap.sh 同一套 knobs），
#     回执第一行现印用的是哪台机——不印就会静默跑到另一台上去。
import io
import json
import os
import subprocess
import sys

cmd = sys.argv[1]
T = int(os.environ.get("W682_T", "280"))
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, ".."))


def _endpoint(env, fallback):
    v = env or fallback
    for cand in (v, os.path.join(root, v), os.path.abspath(v)):
        if os.path.isfile(cand):
            return os.path.abspath(cand)
    return None


CLI = _endpoint(os.environ.get("HRMT_CLI"), os.path.join(root, "hermes-remote", "cli.py"))
if not CLI:
    print("[x] 客户端不在（HRMT_CLI 指错了？）：", os.environ.get("HRMT_CLI") or "hermes-remote/cli.py")
    sys.exit(2)
CFG = os.environ.get("HRMT_CONFIG") or os.path.join(os.path.dirname(CLI), "config.json")
if not os.path.isfile(CFG):
    print("[x] 端点配置不在:", CFG)
    sys.exit(2)
print("端点 CLI=%s CONFIG=%s" % (CLI, CFG))
tmp = os.path.join(here, "w682_rr.json")
p = subprocess.run([sys.executable, CLI, "--config", CFG, "exec", cmd],
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=T)
io.open(tmp, "wb").write(p.stdout)
raw = p.stdout.decode("utf-8-sig", errors="replace")
# ★别整段 unicode_escape：远端中文本来就是 UTF-8 字节，那样解会把 CJK 当 latin-1 再转义一遍(=乱码)。
#   json.loads 自己会把 \n / \uXXXX 正确解出来 ⇒ 只需把 JSON 本体找出来。
i = raw.find("{")
if i < 0:
    print("[x] 回执里找不到 JSON 起点(原样前 900 字节)：")
    print(raw[:900])
    sys.exit(2)
try:
    d = json.loads(raw[i:])
except Exception as e:
    print("[x] JSON 解不开(%s)⇒ 前 900 字节原样：" % e)
    print(raw[:900])
    sys.exit(2)
out = d.get("stdout", "")
print(out)
if d.get("stderr"):
    print("--- stderr ---")
    print(d["stderr"][:1500])
print("=== exit=%s elapsed=%ss truncated=%s ===" % (d.get("exit_code"), d.get("elapsed"), d.get("stdout_truncated")))
sys.exit(0 if d.get("exit_code") == 0 else 1)
