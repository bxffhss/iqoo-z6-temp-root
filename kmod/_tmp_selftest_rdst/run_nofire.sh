#!/usr/bin/env bash
# §6.312 新开关 NOFIRE 的 selftest：把 go.sh 的 fire() **逐字抽出来**跑两格，只 stub 掉 adb 腿 A()。
#   双向判据（例 88/100/116）：不给 NOFIRE ⇒ `am start …ksuarm` 必须照旧发给设备（交付链一字不变）；
#   给了 NOFIRE ⇒ 一条 am start 都不许发，但 `am force-stop` 仍在（要的就是"打停且不扳火"），且要打印 pidof 读回。
#   判据打在**发给设备的命令串**上（A() 记进日志），不打在提示语上。
#   ★包名从 go.sh 现读，不写死在这里——否则脚本改了包名、测试还绿着（例 109/116 那族"判据没有生产者"）。
set -u
cd "$(dirname "$0")/../.." || exit 9
ROOT=$(pwd)
BLK=kmod/_tmp_selftest_rdst/block_nofire.sh
LOG=kmod/_tmp_selftest_rdst/calls_nofire.log
STUB=kmod/_tmp_selftest_rdst/stub_nofire.sh
sed -n '/^fire() {/,/sleep "\$2"; }/p' kmod/go.sh > "$BLK" || exit 8
echo "抽出的块行数=$(wc -l < "$BLK") 字节=$(wc -c < "$BLK")"
grep -q 'NOFIRE' "$BLK" || { echo "FAIL 抽出的块里没有 NOFIRE(锚点错了或改动没落进函数)"; exit 7; }
grep -q 'am force-stop' "$BLK" || { echo "FAIL 块里没有 force-stop 那半(开关不该把停也跳掉)"; exit 7; }
SUW_LINE=$(grep -m1 '^SUW=' kmod/go.sh) || { echo "FAIL go.sh 里没有 SUW= 这行(测试与脚本脱钩)"; exit 6; }
SUW_NAME="${SUW_LINE#SUW=}"
echo "从 go.sh 现读的包名 SUW=$SUW_NAME"

cat > "$STUB" <<'S'
SUW="${SUW_NAME:?}"
A() { printf '%s\n' "$*" >> "${N_LOG:-/dev/null}"; case "$1" in "pidof "*) echo "${FAKE_PIDOF:-}" ;; esac; }
. "$1"
fire w161_g2.sh 0
S

fail=0
run() { # $1=NOFIRE 值(空=不给) $2=期望 $3=忌 $4=标题
    : > "$LOG"
    local out
    if [ -z "$1" ]; then
        out=$( env -u NOFIRE SUW_NAME="$SUW_NAME" N_LOG="$ROOT/$LOG" FAKE_PIDOF="" bash "$ROOT/$STUB" "$ROOT/$BLK" 2>&1 )
    else
        out=$( NOFIRE="$1" SUW_NAME="$SUW_NAME" N_LOG="$ROOT/$LOG" FAKE_PIDOF="" bash "$ROOT/$STUB" "$ROOT/$BLK" 2>&1 )
    fi
    local calls p n
    calls=$(cat "$LOG")
    if [ -z "$2" ]; then p=OK; elif grep -qF -- "$2" <<<"$calls"; then p=OK; else p=MISS; fi
    if [ -z "$3" ]; then n=OK; elif grep -qF -- "$3" <<<"$calls"; then n=BAD; else n=OK; fi
    { [ "$p" = OK ] && [ "$n" = OK ]; } || fail=1
    echo "  [$p/$n] ${4:-}  NOFIRE=[${1:-<未给>}]"
    echo "          发给设备：期望「${2:-<不查>}」 忌「${3:-<不查>}」"
    sed 's/^/              /' <<<"$calls"
    if [ -n "$1" ]; then
        grep -q "读回 pidof" <<<"$out" || { echo "          [MISS] 没有 pidof 读回那行(形状词没生产者)"; fail=1; }
    fi
}
echo "=== 格1 不给 NOFIRE：am start 扳机必须仍发(交付链不变) ==="
run '' "am start -n $SUW_NAME/.MainActivity --es auto ksuarm --es cmd \"w161_g2.sh\"" ''
echo "=== 格2 给 NOFIRE=1：一条 am start 都不许发，force-stop 仍在 ==="
run '1' "am force-stop $SUW_NAME" "am start -n $SUW_NAME"
echo "=== 语法检查 ==="
bash -n kmod/go.sh && echo "  bash -n rc=0" || { echo "  bash -n FAIL"; fail=1; }
echo "=== 结论：selftest $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
