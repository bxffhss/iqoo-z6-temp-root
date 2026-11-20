#!/usr/bin/env bash
# w682_rr.py 端点闸的 selftest（10-28 迁到第二台容器换来的一道闸）。
#   ★一手凭据：w682_rr.py 以前写死 `cfg = ../hermes-remote` 再 `subprocess.run(["cli.py"], cwd=cfg)`，
#     换机后它会**静默在旧机上跑**——回执照样绿，但那盏灯已经不是当前这台机的。
#     同一课已经打进 w999_runcap.sh / w985_run.sh（HRMT_CLI knobs），这份补上第三个入口。
#   ★我自己写这条判据时踩到的坑（留着当反面教材）：在真机上第一次跑"B 格=新机"时忘了写
#     `HRMT_CLI=` 前缀，两格都打到旧机却都"通过" ⇒ 派下去的东西必须现印用的是哪个端点，
#     判据要盯那行字，不能盯我脑子里的假设。另外 Windows 的 abspath 是反斜杠，
#     拿 `case … *"$相对路径>"*` 去比会**假红** ⇒ 这里只比文件名，且证人取桩件自己记的那行。
#   五格（全离线，桩件顶掉真客户端，一条网络都不发；双向＋正负对照）：
#     A HRMT_CLI=桩(相对仓根的写法) ⇒ rc=0 ＋ 桩记到 1 次 ＋ 端点那行印的是桩 ＋ 桩的 stdout 读回来
#     B HRMT_CLI=桩(绝对路径的写法) ⇒ 同上（文档里两种写法都有，都得吃）
#     C HRMT_CLI=不存在的客户端      ⇒ rc=2 ＋ 桩 0 次 ＋ 明说"客户端不在" ★去掉那道 return 这格就红
#     D HRMT_CONFIG=不存在的配置      ⇒ rc=2 ＋ 桩 0 次 ★配置没牙的话会拿着旧机配置照样绿
#     E 源码静态守门                 ⇒ 默认值仍指 hermes-remote(交付形状没变) ＋ 端点确实往 stdout 印
set -u
cd "$(dirname "$0")/../.." || exit 9
RR=kmod/w682_rr.py
EP=kmod/_tmp_selftest_rdst/epstub
STUB=$EP/cli.py
STUBCFG=$EP/config.json
CNT=kmod/_tmp_selftest_rdst/calls_endpoint.log
[ -f "$RR" ] || { echo "FAIL 找不到 $RR"; exit 7; }
grep -q 'HRMT_CLI' "$RR" || { echo "FAIL $RR 里没有 HRMT_CLI 这个 knobs ⇒ 改动没落进去"; exit 7; }

# ★夹具形状要照着**代码真实要求**的形状搭：这原件的规矩是"配置默认取客户端同目录的 config.json"，
#   所以桩必须自带一份邻接 config.json。第一版我把桩扔在 _tmp_selftest_rdst 里、旁边没有配置，
#   于是 A/B 两格红在"配置不在"——那是**我的夹具不对**，不是被测件坏（例 189① 又一例）。
mkdir -p "$EP" || exit 9
echo '{"url":"stub-endpoint","username":"stub","password":"stub"}' > "$STUBCFG"

cat > "$STUB" <<'PY'
# 桩：把收到的参数原样记进 $N_CNT，再吐一份 cli.py 形状的回执。
#   ★记的是**桩自己的绝对路径 ＋ 收到的全部参数**——"到底用了哪个端点、配置传没传下去"
#     必须由被叫起来的那一方作证，不叫 w682 自己说（它说什么都可能是猜的）。
import json
import os
import sys
args = sys.argv[1:]
with open(os.environ["N_CNT"], "a") as f:
    f.write(os.path.abspath(__file__) + " | " + " ".join(args) + "\n")
print(json.dumps({"id": "stub", "exit_code": 0, "stdout": "STUB_HOST\n", "stderr": "",
                  "elapsed": 0.1, "timed_out": False, "stdout_truncated": False, "ok": True}))
PY

FAILS=0
cell() {  # $1=格名 $2=期望rc $3=期望桩次数 $4=桩是否必须被叫起(1/0) 之后 env 赋值…
    local name="$1" want_rc="$2" want_cnt="$3" need_hit="$4"
    shift 4
    : > "$CNT"
    local out rc cnt hit cfgw
    out=$(env N_CNT="$PWD/$CNT" "$@" PYTHONUTF8=1 python "$RR" 'hostname' 2>&1)
    rc=$?
    cnt=$(wc -l < "$CNT" | tr -d ' ')
    hit=$(grep -c 'epstub' "$CNT" | tr -d ' ')
    # ★"配置传下去了没有"单独数一次：只验"用了哪个客户端"不够，配置指错机时客户端仍会绿。
    cfgw=$(grep -c -- '--config' "$CNT" | tr -d ' ')
    local bad=""
    [ "$rc" = "$want_rc" ] || bad="$bad rc=$rc(要 $want_rc)"
    [ "$cnt" = "$want_cnt" ] || bad="$bad 桩次数=$cnt(要 $want_cnt)"
    if [ "$need_hit" = 1 ]; then
        [ "$hit" = 1 ] || bad="$bad 桩没被叫起"
        [ "$cfgw" = 1 ] || bad="$bad --config 没传给客户端(次数=$cfgw)"
    fi
    # ★"端点现印"只在"这一格本该跑通"时要求：C/D 是拦下来的形状，它印的是"[x] …不在"，
    #   拿同一条要求去卡它们会把**闸判成被测**（假红）。
    if [ "$need_hit" = 1 ]; then
        case "$out" in *"端点 CLI="*) : ;; * ) bad="$bad 端点没现印";; esac
    fi
    if [ -z "$bad" ]; then
        echo "  [OK] $name (rc=$rc 桩=$cnt)"
    else
        echo "  [BAD] $name :$bad"
        echo "        回执前 240 字：$(printf %s "$out" | head -c 240)"
        FAILS=$((FAILS + 1))
    fi
    LAST="$out"
}

cell "A 相对路径端点被真的用上(配置跟着客户端走)" 0 1 1 HRMT_CLI="$STUB"
# 桩的 stdout 必须读回来（否则"用了哪个端点"只对了一半，输出通道也可能是假的）
case "$LAST" in *STUB_HOST*) echo "  [OK] A2 桩的 stdout 读回来了" ;;
    *) echo "  [BAD] A2 没读回 STUB_HOST"; FAILS=$((FAILS + 1)) ;;
esac
cell "B 绝对路径端点(两种写法都得吃)" 0 1 1 HRMT_CLI="$PWD/$STUB"
cell "C 指错客户端必须响、不许静默回退" 2 0 0 HRMT_CLI="no_such_dir/cli.py"
case "$LAST" in *"客户端不在"*) echo "  [OK] C2 说了为什么失败" ;;
    *) echo "  [BAD] C2 没说清原因"; FAILS=$((FAILS + 1)) ;;
esac
cell "D 端点配置不在也要拦" 2 0 0 HRMT_CLI="$STUB" HRMT_CONFIG="no_such/config.json"

if grep -q 'os.path.join(root, "hermes-remote", "cli.py")' "$RR" \
   && grep -q 'print("端点 CLI=' "$RR"; then
    echo "  [OK] E 静态：默认仍指 hermes-remote(交付形状没变) ＋ 端点现印进 stdout"
else
    echo "  [BAD] E 静态：默认值或'端点现印'被改掉了"
    FAILS=$((FAILS + 1))
fi

rm -f "$CNT" "$STUB" "$STUBCFG"
rmdir "$EP" 2>/dev/null
echo "失败格数=$FAILS"
echo "=== 结论：run_endpoint $([ "$FAILS" = 0 ] && echo PASS || echo FAIL)（A/A2/B 正对照＋C/C2/D 负对照＋E 静态守门＝7 格）==="
[ "$FAILS" = 0 ] || exit 8
