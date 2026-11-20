#!/usr/bin/env bash
# §6.307③ 新开关(dmesg.live 存档不删)的 selftest：把 go.sh 里那段**逐字抽出来**跑两格。
#   只 stub 掉 adb 腿 A()，并把 A() 收到的每条命令记进日志——因为真块里的 A 都带 >/dev/null，
#   只看 stdout 就只能证明"提示语打印了"、证不了"命令真的发出去了"(例 100：接受≠生效)。
#   双向判据：上一发没留文件 ⇒ 绝不许出现 mv(否则把别人的名字搬走)；留了 ⇒ 必须 mv 成带时间戳的 prev 名，且 rm 仍在。
set -u
cd "$(dirname "$0")/../.." || exit 9
ROOT=$(pwd)
BLK=kmod/_tmp_selftest_rdst/block_salvage.sh
LOG=kmod/_tmp_selftest_rdst/calls.log
sed -n '/★§6.307：dmesg.live/,/rm -f \/data\/local\/tmp\/ksu_stage.log/p' kmod/go.sh > "$BLK" || exit 8
echo "抽出的块行数=$(wc -l < "$BLK") 字节=$(wc -c < "$BLK")"
grep -q 'dmesg.live.prev_' "$BLK" || { echo "FAIL 抽出的块里没有改名行(锚点错了或改动没落进去)"; exit 7; }
grep -q 'wc -c < /data/local/tmp/dmesg.live' "$BLK" || { echo "FAIL 大小读数不是 wc -c 形式(awk/\$ 在双引号里会被本机炸，见环境账)"; exit 7; }

cat > kmod/_tmp_selftest_rdst/stub_salvage.sh <<'S'
A() {
    printf '%s\n' "$*" >> "${SALVAGE_LOG:-/dev/null}"
    case "$1" in
        *"wc -c <"*)   echo "${FAKE_SIZE:-0}" ;;
        *"date +%m%d"* ) echo "${FAKE_DATE:-1016-2359}" ;;
    esac
}
. "$1"
S

fail=0
run() { # $1=设备上残留字节数 $2=命令日志里期望出现(可空) $3=命令日志里期望不出现(可空) $4=标题
    : > "$LOG"
    local out
    out=$( SALVAGE_LOG="$ROOT/$LOG" FAKE_SIZE="$1" FAKE_DATE="1016-2359" bash "$ROOT/kmod/_tmp_selftest_rdst/stub_salvage.sh" "$ROOT/$BLK" 2>&1 )
    local p n calls
    calls=$(cat "$LOG")
    if [ -z "$2" ]; then p=OK
    elif grep -qF -- "$2" <<<"$calls"; then p=OK; else p=MISS; fi
    if [ -z "$3" ]; then n=OK
    elif grep -qF -- "$3" <<<"$calls"; then n=BAD; else n=OK; fi
    { [ "$p" = OK ] && [ "$n" = OK ]; } || fail=1
    echo "  [$p/$n] ${4:-}  残留字节=[${1:-<无>}]"
    echo "          发给设备的命令里：期望「${2:-<不查>}」 忌「${3:-<不查>}」"
    sed 's/^/              /' <<<"$calls"
}
echo "=== 格1 上一发没留 dmesg.live(0 字节)：不许出现 mv，rm 那条照旧 ==="
run '0' 'rm -f /data/local/tmp/ksu_stage.log' 'mv -f /data/local/tmp/dmesg.live'
echo "=== 格2 上一发留了 17849330 字节：必须 mv 成 prev_1016-2359，且 rm 仍在(旧名要清掉) ==="
run '17849330' 'mv -f /data/local/tmp/dmesg.live /data/local/tmp/dmesg.live.prev_1016-2359' ''
grep -qF 'rm -f /data/local/tmp/ksu_stage.log' "$LOG" || { echo "  [MISS] 格2 之后 rm 那条不在了 ⇒ 会跨发串名"; fail=1; }
echo "=== 语法检查 ==="
bash -n kmod/go.sh && echo "  bash -n rc=0" || { echo "  bash -n FAIL"; fail=1; }
echo "=== 结论：selftest $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
