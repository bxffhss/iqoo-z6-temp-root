#!/usr/bin/env bash
# §6.301⑤ 仪器开关的 selftest：把 go.sh 的 1.6 段**逐字抽出来**跑三格，只 stub 掉 adb 腿 A()。
# 判据是双向的：默认关时行为必须与现在一致；给了 REDIRECT_DST 才铺落点；args 自己给了 ksud_path 时开关必须让位。
set -u
cd "$(dirname "$0")/../.." || exit 9
ROOT=$(pwd)
BLK=kmod/_tmp_selftest_rdst/block.sh
sed -n '/=== 1.6/,/=== 1.7/p' kmod/go.sh > "$BLK" || exit 8
echo "抽出的块行数=$(wc -l < "$BLK") 字节=$(wc -c < "$BLK")"
grep -q 'KSUD_P=$(tr' "$BLK" || { echo "FAIL 抽出的块里没有 KSUD_P 解析行(锚点错了)"; exit 7; }
grep -q 'REDIRECT_DST' "$BLK" || { echo "FAIL 抽出的块里没有 REDIRECT_DST(改动没落进 1.6 段)"; exit 7; }

cat > kmod/_tmp_selftest_rdst/stub.sh <<'S'
A() { echo "ADB[$*]"; }
. "$1"
S

WORK=$(mktemp -d)
fail=0
run() { # $1=args 内容 $2=REDIRECT_DST(可空) $3=期望关键字 $4=不该出现的关键字
    mkdir -p "$WORK/kmod"
    printf '%s' "$1" > "$WORK/kmod/ksu_args.txt"
    local out
    if [ -n "$2" ]; then
        out=$( cd "$WORK" && REDIRECT_DST="$2" bash "$ROOT/kmod/_tmp_selftest_rdst/stub.sh" "$ROOT/$BLK" 2>&1 )
    else
        out=$( cd "$WORK" && env -u REDIRECT_DST bash "$ROOT/kmod/_tmp_selftest_rdst/stub.sh" "$ROOT/$BLK" 2>&1 )
    fi
    local p n
    if grep -qF -- "$3" <<<"$out"; then p=OK; else p=MISS; fi
    if [ -n "$4" ] && grep -qF -- "$4" <<<"$out"; then n=BAD; else n=OK; fi
    { [ "$p" = OK ] && [ "$n" = OK ]; } || fail=1
    echo "  [$p/$n] args=[$1]"
    echo "          REDIRECT_DST=[${2:-<未给>}]  期望含「$3」 忌含「${4:-无}」"
    sed 's/^/            /' <<<"$out"
}
echo "=== 格1 默认关(args 无 ksud_path)：必须仍走 rm 分支(交付链行为不变) ==="
run 'ksu_mass_mark=0 ksu_hook_mask=0x2' '' '已清掉 dst/con' '已写 dst/con'
echo "=== 格2 给 REDIRECT_DST(args 无 ksud_path)：必须铺落点，写的是给的那条 ==="
run 'ksu_mass_mark=0 ksu_hook_mask=0x2' '/data/local/tmp/kd' '/data/local/tmp/kd > /data/local/tmp/ksu_redirect_dst' '已清掉 dst/con'
echo "=== 格3 args 自己给了 ksud_path：开关必须让位(以 args 为准) ==="
run 'ksu_mass_mark=0 ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/data/local/tmp/kd' '/data/local/tmp/zzz' 'ksu_ksud_path=/data/local/tmp/kd' 'zzz > /data/local/tmp/ksu_redirect_dst'
rm -rf "$WORK"
echo "=== 语法检查 ==="
bash -n kmod/go.sh && echo "  bash -n rc=0" || { echo "  bash -n FAIL"; fail=1; }
echo "=== 结论：selftest $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
