#!/usr/bin/env bash
# §6.310 新增的 QUIET 开关 selftest：把 go.sh 的 1.65 段**逐字抽出来**跑三格，只 stub 掉 adb 腿 A()。
#   判据打在"真正发给设备的命令串"上而不是提示语(例 100/109)：
#   格1 不给 QUIET ⇒ 绝不许出现 touch 那两个开关(交付链行为必须逐字不变)；
#   格2 给 QUIET=1  ⇒ 必须同时 touch 两个开关，且带一次 ls 读回；
#   格3 反例(只给一个) ⇒ 只能 touch 那一个？——不，本开关语义是"两个一起"，所以格3 验的是"两个都在"，
#         并额外要求提示语里出现"事后用 grep 复证"那句(提醒下一双眼睛去 stage 日志确认生效行)。
set -u
cd "$(dirname "$0")/../.." || exit 9
ROOT=$(pwd)
BLK=kmod/_tmp_selftest_rdst/block_quiet.sh
LOG=kmod/_tmp_selftest_rdst/calls_quiet.log
sed -n '/=== 1.65)/,/=== 1.7)/p' kmod/go.sh > "$BLK" || exit 8
echo "抽出的块行数=$(wc -l < "$BLK") 字节=$(wc -c < "$BLK")"
grep -q 'QUIET' "$BLK" || { echo "FAIL 抽出的块里没有 QUIET(锚点错了或改动没落进去)"; exit 7; }
grep -q 'ksu_quiet_after_insmod' "$BLK" || { echo "FAIL 块里没有 after_insmod 开关"; exit 7; }

cat > kmod/_tmp_selftest_rdst/stub_quiet.sh <<'S'
A() { printf '%s\n' "$*" >> "${Q_LOG:-/dev/null}"; }
. "$1"
S

fail=0
run() { # $1=QUIET 值(<空>=不给) $2=期望出现 $3=期望不出现 $4=标题
    : > "$LOG"
    local out
    if [ -z "$1" ]; then
        out=$( env -u QUIET Q_LOG="$ROOT/$LOG" bash "$ROOT/kmod/_tmp_selftest_rdst/stub_quiet.sh" "$ROOT/$BLK" 2>&1 )
    else
        out=$( QUIET="$1" Q_LOG="$ROOT/$LOG" bash "$ROOT/kmod/_tmp_selftest_rdst/stub_quiet.sh" "$ROOT/$BLK" 2>&1 )
    fi
    local calls p n
    calls=$(cat "$LOG")
    if [ -z "$2" ]; then p=OK
    elif grep -qF -- "$2" <<<"$calls"; then p=OK; else p=MISS; fi
    if [ -z "$3" ]; then n=OK
    elif grep -qF -- "$3" <<<"$calls"; then n=BAD; else n=OK; fi
    { [ "$p" = OK ] && [ "$n" = OK ]; } || fail=1
    echo "  [$p/$n] ${4:-}  QUIET=[${1:-<未给>}]"
    echo "          发给设备的命令：期望「${2:-<不查>}」 忌「${3:-<不查>}」"
    sed 's/^/              /' <<<"$calls"
    if [ -n "$1" ]; then
        grep -q "grep 复证" <<<"$out" || { echo "          [MISS] 提示语里没有「grep 复证」这句(生效复证的提醒丢了)"; fail=1; }
    else
        grep -q "别开枪" <<<"$out" || { echo "          [MISS] 不给 QUIET 时没提醒"这一格若是 quiet 就停下""; fail=1; }
    fi
}
echo "=== 格1 不给 QUIET：一条 touch 都不许发(交付链不变) ==="
run '' '' 'touch /data/local/tmp/ksu_quiet_after_insmod'
echo "=== 格2 给 QUIET=1：两个开关都要 touch，且带 ls 读回 ==="
run '1' 'touch /data/local/tmp/ksu_quiet_after_insmod /data/local/tmp/ksu_quiet_fixcfi' ''
grep -qF 'ls -l /data/local/tmp/ksu_quiet_after_insmod' "$LOG" || { echo "  [MISS] 没有读回 ls"; fail=1; }
echo "=== 语法检查 ==="
bash -n kmod/go.sh && echo "  bash -n rc=0" || { echo "  bash -n FAIL"; fail=1; }
echo "=== 结论：selftest $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
