#!/usr/bin/env bash
# run_watch.sh —— kmod/w422_watch.sh 的**三格离线自测**(桩 adb，不碰设备)。
#   为什么要有：跟随器是"判活/判死"的唯一连续证人。它坏了最典型的形状不是报错，是
#   **拿着上一发的 boot_id 当本发**(例 95/101/114) ⇒ 三格必须把"该停的停、该过的过"都验一遍。
#   做法＝复制真身，只把"取读数"那一行换成读序列文件的桩、并把 sleep 60 缩掉(测的是逻辑不是节拍)。
set -u
cd "$(dirname "$0")/../.." || exit 1
W=$(mktemp -d)
nchk=0; fail=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

cp kmod/w422_watch.sh "$W/w.sh"
sed -i -e 's|^    ROW=.*|    ROW=$(STUBFN)|' -e 's|^    i=\$((i+1)); sleep 60|    i=$((i+1)); sleep 0.02|' "$W/w.sh"
# ★护栏数的是**副本**里的替换落地次数(不是本文件的文案)：两处各 1 次才算真在测真身
[ "$(grep -c 'ROW=\$(STUBFN)' "$W/w.sh")" = 1 ] || { echo "[x] 读数桩没替换上 ⇒ 测的是空气"; exit 1; }
[ "$(grep -c 'sleep 0.02' "$W/w.sh")" = 1 ] || { echo "[x] sleep 没缩 ⇒ 会干等 60 秒，测具不对"; exit 1; }
grep -q '^    ROW=\$(MSYS_NO_PATHCONV' "$W/w.sh" && { echo "[x] 副本里还留着真 adb 读数"; exit 1; }
echo "副本行数=$(wc -l < "$W/w.sh")(真身 $(wc -l < kmod/w422_watch.sh))"

run() { # $1=tag $2=多行读数序列(每行=一格)
    printf '%s\n' "$2" > "$W/seq_$1.txt"
    echo 0 > "$W/n_$1"
    cat > "$W/stub_$1.sh" <<EOF
STUBFN() { local n; n=\$(cat "$W/n_$1"); n=\$((n+1)); echo \$n > "$W/n_$1"; sed -n "\${n}p" "$W/seq_$1.txt"; }
EOF
    (
        . "$W/stub_$1.sh"; export -f STUBFN
        timeout 40 bash "$W/w.sh" ABC-1111 100.00 > "$W/out_$1.txt" 2>&1
    )
    echo "----- case $1 -----"
    sed 's/^/    /' "$W/out_$1.txt"
}

run pass 'up=200 mod=1 bid=ABC-1111
up=1950 mod=1 bid=ABC-1111'
run newboot 'up=200 mod=1 bid=ABC-1111
up=2600 mod=1 bid=ZZZ-9999'
run mod0 'up=200 mod=1 bid=ABC-1111
up=205 mod=0 bid=ABC-1111'

# ★"不许出现"那半边只匹配**判决短语**，不匹配"判活"二字——表头"判活线 up>=…"里就含它，
#   第一版因此把两个行为正确的格子判成红(例 106：共用文案不是证据)。线本身仍由我重算(例 91/127)。
LINEW=$(awk 'BEGIN{printf "%d", 100+1800}')
chk "①过线格：打出『过线…判活』且线就是我算的 $LINEW" "$(grep -aq "过线(up=1950≥$LINEW) ⇒ 判活" "$W/out_pass.txt" && echo 1 || echo 0)"
chk "②换 boot：即使 up 早已过线也必须停、且不许出判决(只认判决短语，表头那句含『判活线』不算)" "$(grep -aq 'boot 变了' "$W/out_newboot.txt" && ! grep -aq '⇒ 判活，停' "$W/out_newboot.txt" && echo 1 || echo 0)"
chk "③mod 掉回 0：必须停且不许出判决" "$(grep -aq 'mod=0 ⇒ 模块没了' "$W/out_mod0.txt" && ! grep -aq '⇒ 判活，停' "$W/out_mod0.txt" && echo 1 || echo 0)"
# ★第四格(例 88"第一遍真的改了")：桩没被调用＝这一套在测空气
N1=$(cat "$W/n_pass" 2>/dev/null || echo 0)
chk "④桩确实被调用过(过线格读了 $N1 次，≥2 才算真跑过循环)" "$([ "${N1:-0}" -ge 2 ] && echo 1 || echo 0)"

rm -rf "$W"
echo
[ "$fail" = 0 ] && echo "=== run_watch 自测 PASS($nchk 项，条数由 chk 自数) ===" || echo "=== FAIL($nchk 项里有红) ==="
[ "$fail" = 0 ]
