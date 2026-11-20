#!/usr/bin/env bash
# go.sh 3.5) LEG1 派腿段的 selftest（第 69 发空枪换来的一道闸：腿在设备上必须有 x 位）。
#   ★一手凭据：sushd.log 里 `cmd=[/data/local/tmp/w1018_mlsrange_leg.sh]` 后面跟
#     `已回给 uid=10342 输出 82 字节 exit=126(有输出)` 与 `KSU_EXEC: … can't execute: Permission denied`
#     ⇒ 通道好、授权 granted=1，死在 execve：adb push 把腿落成 0666，**root 也要至少一个 x 位**。
#   六格（双向＋正对照，例 88/100/116/192 的规矩）：
#     A 不给 LEG1            ⇒ 整段只做"未给"那一句，一条 adb 都不许发(交付形状一字不变)
#     B 已经 755              ⇒ 必须发 FIRE，且 chmod 次数=0(闸不许对好形状多动手)
#     C 先 666、chmod 后 755  ⇒ 必须 chmod 恰好 1 次 ＋ 第二次 ls 读回 ＋ 仍发 FIRE
#     D chmod 治不好(两次都 666) ⇒ 不许 FIRE ＋ 必须印"不派"
#     E ls 回的是错误文本(路径里带 1018 这种数字) ⇒ 不许 FIRE ★这条就是"读不到被判成有 x"的变异格
#     F md5 两端不符          ⇒ 不许 FIRE ★修掉的旧缺陷：以前置 LEG1=1 之后照样 fire，等于把字面量『1』派下去
#   ★判据打在**发给设备的命令串**上(stub 的 A()/fire() 记进日志)，不打在提示语上；
#     但"拦下了要说明为什么拦"这类文案也各查一条，免得闸哑掉。
#   ★抽取本身要有牙，并且**这道闸删掉就得变红**——10-28 变异跑过：
#     awk '/第 69 发一手的第二道自保闸/{d=1} d==0{print} d==1 && /^        fi$/{d=0}' kmod/go.sh > 变异件
#     ⇒ 把 selftest 的 G= 指到变异件：抽块少 24 行、rc=7、[OK] 行数=0(总闸那格期望 6) ⇒ 红。
set -u
cd "$(dirname "$0")/../.." || exit 9
G=kmod/go.sh
BLK=kmod/_tmp_selftest_rdst/block_exebit.sh
S=kmod/_tmp_selftest_rdst/synth_exebit.sh
LOG=kmod/_tmp_selftest_rdst/calls_exebit.log

# ★锚点用的是"第二处 if [ -n "${LEG1:-}" ]"：第一处属于 3.5 的 quiet 闸(它有专属 selftest run_quietguard.sh)。
#   收尾吃到**第一个顶格 fi**＝整块自带 else/fi ⇒ cell A 才能真的走到"未给 LEG1 ⇒ 不派腿"那一支。
awk '/^if \[ -n "\$\{LEG1:-\}" \]; then$/{c++} c==2{f=1} f{print} f&&/^fi$/{exit}' "$G" > "$BLK"
BYTES=$(wc -c < "$BLK"); LINES=$(wc -l < "$BLK")
echo "抽出的派腿块：行数=$LINES 字节=$BYTES"
[ "$BYTES" -gt 600 ] || { echo "FAIL 块太小(=$BYTES 字节)＝锚点错了或改动没落进 go.sh"; exit 7; }
grep -q 'can.t execute\|没有 x 位' "$BLK" || { echo "FAIL 块里没有 x 位那条判据(第 69 发的改动没落进函数)"; exit 7; }
grep -q 'chmod 755' "$BLK" || { echo "FAIL 块里没有补 x 位那句"; exit 7; }
grep -q 'fire "@sushd' "$BLK" || { echo "FAIL 块里没有 fire ⇒ 抽出的是别的东西，判据没被测到"; exit 7; }

cat > "$S" <<'SHEBANG'
LOG="${N_LOG}"
# ★第 69 发 selftest 自己踩到的坑(记进 md)：ls 的"第几次调用"要记在**文件**里，
#   不能记在变量上——go.sh 那句是 `PERM=$(A "ls -l …" | awk …)`，A() 跑在**命令替换的子 shell**里，
#   变量计数器每次都回到 0 ⇒ 第二次读回永远拿到 FAKE_LS1 ⇒ C 格被我的仪器判成"补不上"。
#   红的是仪器不是被测，所以这里两侧都要有牙。
ls_n() { local n; n=$(cat "$CNT" 2>/dev/null); n=${n:-0}; n=$((n+1)); printf '%s' "$n" > "$CNT"; printf '%s' "$n"; }
A() {
    printf 'ADB|%s\n' "$1" >> "$LOG"
    case "$1" in
        ls\ -l\ * )
            if [ "$(ls_n)" = 1 ]; then printf '%s\n' "${FAKE_LS1:-}"; else printf '%s\n' "${FAKE_LS2:-}"; fi ;;
        chmod* ) : ;;
        md5sum* ) printf '%s  leg\n' "${FAKE_MD5:-deadbeef}" ;;
        rm\ -f* ) : ;;
        cat* ) printf 'END up=1\n' ;;
    esac
}
fire() { printf 'FIRE|%s\n' "$1" >> "$LOG"; }
WAITFOR() { printf 'END up=1\n' > "$EV/leg1_out.txt"; return 0; }
SHEBANG
cat "$BLK" >> "$S"
echo 'echo "FINAL_LEG1=[${LEG1:-<空>}]"' >> "$S"
bash -n "$S" || { echo "FAIL 拼出来的夹具语法不过"; exit 7; }

fail=0
run() { # $1=LEG1 $2=LS1 $3=LS2 $4=标题  其余走环境变量期望
    : > "$LOG"
    local f0=$fail out
    mkdir -p "$ROOT/kmod/_tmp_selftest_rdst/ev_exebit" 2>/dev/null
    rm -f "$ROOT/kmod/_tmp_selftest_rdst/calls_exebit.cnt"
    out=$( LEG1="$1" LEG1OUT=/data/local/tmp/x.out LEG1MD5="${F_MD5:-}" \
           FAKE_LS1="$2" FAKE_LS2="$3" FAKE_MD5="${F_DEVMD5:-cafef00d}" \
           N_LOG="$ROOT/$LOG" CNT="$ROOT/kmod/_tmp_selftest_rdst/calls_exebit.cnt" \
           EV="$ROOT/kmod/_tmp_selftest_rdst/ev_exebit" \
           bash "$ROOT/$S" 2>&1 )
    local calls nf nc
    calls=$(cat "$LOG" 2>/dev/null)
    nf=$(grep -c '^FIRE|' <<<"$calls"); nf=${nf:-0}
    nc=$(grep -c '^ADB|chmod' <<<"$calls"); nc=${nc:-0}
    echo "  [$4]"
    echo "      FIRE 次数=$nf  chmod 次数=$nc"
    sed 's/^/          /' <<<"$calls"
    grep -q 'FINAL_LEG1' <<<"$out" || { echo "      [BAD] 夹具没跑出最后一行(中途炸了)"; echo "$out" | tail -3 | sed 's/^/          /'; fail=1; }
    # 逐格期望由调用前的 EXP_* 变量给
    if [ -n "${EXP_FIRE:-}" ] && [ "$nf" != "$EXP_FIRE" ]; then echo "      [BAD] FIRE 期望 $EXP_FIRE 实得 $nf"; fail=1; fi
    if [ -n "${EXP_CHMOD:-}" ] && [ "$nc" != "$EXP_CHMOD" ]; then echo "      [BAD] chmod 期望 $EXP_CHMOD 实得 $nc"; fail=1; fi
    if [ -n "${EXP_NOFIRE_REASON:-}" ] && ! grep -q "$EXP_NOFIRE_REASON" <<<"$out"
        then echo "      [MISS] 拦下了但没说为什么(文案没有生产者)：要含「$EXP_NOFIRE_REASON」"; fail=1; fi
    if [ -n "${EXP_FINAL:-}" ] && ! grep -q "FINAL_LEG1=$EXP_FINAL" <<<"$out"
        then echo "      [BAD] 末态期望 FINAL_LEG1=$EXP_FINAL 实得 $(grep -o 'FINAL_LEG1=.*' <<<"$out")"; fail=1; fi
    # ★w413 数的是 [OK] 行数(总闸里这一件的期望=6)：不印这个词，这件在总闸里就是"0 格也绿"
    [ "$fail" = "$f0" ] && echo "      [OK] $4 这一格六项期望全中"
    EXP_FIRE=""; EXP_CHMOD=""; EXP_NOFIRE_REASON=""; EXP_FINAL=""
    F_DEVMD5=""; F_MD5=""
}
ROOT=$(pwd)
mkdir -p kmod/_tmp_selftest_rdst/ev_exebit

echo "=== A) 不给 LEG1 ⇒ 一条 adb 都不发(交付形状逐字不变) ==="
EXP_FIRE=0; EXP_CHMOD=0
run '' '' '' 'A 不给 LEG1'

echo "=== B) 正对照：腿已经 755 ⇒ 必须真的派下去(chmod 一次都不许多) ==="
EXP_FIRE=1; EXP_CHMOD=0; EXP_FINAL='\[/data/local/tmp/x.sh\]'
run '/data/local/tmp/x.sh' '-rwxr-xr-x 1 shell shell 5895 2026-10-27 22:40 /data/local/tmp/x.sh' '' 'B 已有 x 位'

echo "=== C) 腿 0666 ⇒ 补 x 位＋复读到 755 ⇒ 仍然派 ==="
EXP_FIRE=1; EXP_CHMOD=1
run '/data/local/tmp/x.sh' '-rw-rw-rw- 1 shell shell 5895 2026-10-27 22:40 /data/local/tmp/x.sh' \
                       '-rwxr-xr-x 1 shell shell 5895 2026-10-28 00:10 /data/local/tmp/x.sh' 'C 补得上'

echo "=== D) chmod 治不好(两次都 666) ⇒ 不许派，且要说为什么 ==="
EXP_FIRE=0; EXP_CHMOD=1; EXP_NOFIRE_REASON='没有 x 位'; EXP_FINAL='\[1\]'
run '/data/local/tmp/x.sh' '-rw-rw-rw- 1 shell shell 5895 2026-10-27 22:40 /data/local/tmp/x.sh' \
                       '-rw-rw-rw- 1 shell shell 5895 2026-10-27 22:40 /data/local/tmp/x.sh' 'D 补不上⇒不派'

echo "=== E) ls 回错误文本(路径自带数字) ⇒ 这是「读不到」，不许判成「有 x」 ==="
EXP_FIRE=0; EXP_NOFIRE_REASON='没有 x 位'
run '/data/local/tmp/x.sh' "ls: /data/local/tmp/w1018_mlsrange_leg.sh: No such file or directory" \
                       "ls: /data/local/tmp/w1018_mlsrange_leg.sh: No such file or directory" 'E 读不到⇒不派'

echo "=== F) md5 两端不符 ⇒ 不许派(旧缺陷：置 LEG1=1 之后照样 fire) ==="
EXP_FIRE=0
F_DEVMD5=notthesame
F_MD5=abc123
run '/data/local/tmp/x.sh' '-rwxr-xr-x 1 shell shell 5895 2026-10-27 22:40 /data/local/tmp/x.sh' '' 'F md5 不符⇒不派'
F_DEVMD5=""
echo "=== 真 go.sh 语法 ==="
bash -n "$G" && echo "  bash -n rc=0" || { echo "  bash -n FAIL"; fail=1; }
echo "=== 结论：selftest $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ==="
exit "$fail"
