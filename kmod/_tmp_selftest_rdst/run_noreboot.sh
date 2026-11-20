#!/usr/bin/env bash
# NOREBOOT 开关的 selftest(§6.515)：把 go.sh 第 2a 段**逐字抽出来**跑三格。
#   双向判据(例 88/100/116/192)：
#     格1 不给 NOREBOOT ⇒ 照旧 `adb reboot`(交付链一字不变)；
#     格2 给 NOREBOOT=1 且当前 boot 干净 ⇒ 不许碰 reboot，但必须**明写跳过**(缺席不许静默)；
#     格3 给 NOREBOOT=1 但当前 boot 已经有 kernelsu ⇒ 必须**拒**(exit 3)，不许在脏 boot 上开窗。
#   ★抽取本身要有牙(例 192②)：先断言抽出的块非空、含 NOREBOOT 与 kernelsu 那把闸，否则锚点错了测试永远绿。
#   ★夹具里的 `adb`/`A`/`sleep` 全是桩：这一格只问"走哪条支、说没说跳过、拒没拒"，不碰真机。
set -u
cd "$(dirname "$0")/../.." || exit 9
G=kmod/go.sh
BLK=kmod/_tmp_selftest_rdst/block_noreboot.sh
F=kmod/_tmp_selftest_rdst/synth_noreboot.sh

sed -n '/^# === 2a) NOREBOOT/,/^# === 2a-end)/p' "$G" | sed '1d;$d' > "$BLK"
echo "抽出的 NOREBOOT 块：行数=$(wc -l < "$BLK") 字节=$(wc -c < "$BLK")"
[ "$(wc -c < "$BLK")" -gt 120 ] || { echo "FAIL NOREBOOT 块抽空了(锚点错了或改动没落进 go.sh)"; exit 7; }
grep -q 'NOREBOOT' "$BLK" || { echo "FAIL 块里没有 NOREBOOT(开关名没落进去)"; exit 7; }
grep -q 'kernelsu' "$BLK" || { echo "FAIL 块里没有 kernelsu 那把"脏 boot 必拒"的闸(抽错段了)"; exit 7; }
grep -q 'adb reboot' "$BLK" || { echo "FAIL 块里没有 else 支的 adb reboot(⇒ 格1 根本没法判)"; exit 7; }

{
  echo 'set -u'
  echo 'sleep(){ :; }'
  echo 'adb(){ if [ "$1" = reboot ]; then echo ADB_CALLED_REBOOT; else echo device; fi; }'
  echo 'A(){ case "$1" in'
  echo '  *kernelsu*) echo "${MOCK_MODS:-0}" ;;'
  echo '  *uptime*) echo 42.5 ;;'
  echo '  *sys.boot_completed*) echo 1 ;;'
  echo '  *boot.reason.history*) echo "reboot,shell,1793560000" ;;'
  echo '  *ro.boot.bootreason*) echo reboot ;;'
  echo '  *) echo "" ;; esac; }'
  cat "$BLK"
  echo 'echo AFTER_BLOCK_RAN'
} > "$F"
bash -n "$F" || { echo "FAIL 拼出来的合成脚本语法不过"; exit 7; }

fail=0
run() { # $1=NOREBOOT 值(空=不给) $2=MOCK_MODS $3=期望词 $4=忌词 $5=期望rc $6=标题
    local out rc p n q
    if [ -z "$1" ]; then
        out=$(env -u NOREBOOT MOCK_MODS="$2" bash "$F" 2>&1); rc=$?
    else
        out=$(NOREBOOT="$1" MOCK_MODS="$2" bash "$F" 2>&1); rc=$?
    fi
    if grep -qF -- "$3" <<<"$out"; then p=OK; else p=MISS; fi
    if [ -z "$4" ]; then n=OK; elif grep -qF -- "$4" <<<"$out"; then n=BAD; else n=OK; fi
    if [ "$rc" = "$5" ]; then q=OK; else q=RCBAD; fi
    { [ "$p" = OK ] && [ "$n" = OK ] && [ "$q" = OK ]; } || fail=1
    echo "  [$p/$n/$q] $6  NOREBOOT=[${1:-<未给>}] MOCK_MODS=$2 rc=$rc(要 $5)"
    # ★w413 数的是 [OK] 行数(总闸那条 item 的期望=3)；没有这个词这条 selftest 在总闸里就是"0 格也绿"
    { [ "$p" = OK ] && [ "$n" = OK ] && [ "$q" = OK ]; } && echo "      [OK] $6"
    sed 's/^/              /' <<<"$out"
}
echo "=== 格1 不给 NOREBOOT ⇒ 照旧 reboot(交付形状不变) ==="
run '' 0 'ADB_CALLED_REBOOT' '跳过 adb reboot' 0 '交付形状照旧 reboot'
echo "=== 格2 NOREBOOT=1 且当前 boot 干净 ⇒ 不 reboot，但必须明写跳过 ==="
run '1' 0 '跳过 adb reboot' 'ADB_CALLED_REBOOT' 0 '开关生效且明说跳过'
echo "=== 格3 NOREBOOT=1 但当前 boot 已有 kernelsu ⇒ 必拒(exit 3，且不许走到开窗) ==="
run '1' 1 '当前 boot 已经有 kernelsu' 'AFTER_BLOCK_RAN' 3 '脏 boot 必拒'

echo "=== 语法检查(真 go.sh) ==="
if bash -n "$G"; then echo "  bash -n rc=0"; else echo "  bash -n FAIL"; fail=1; fi
echo "=== 结论：selftest $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ==="
exit "$fail"
