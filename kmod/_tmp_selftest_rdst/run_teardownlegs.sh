#!/usr/bin/env bash
# run_teardownlegs.sh —— #153 给收尾件加的两条腿的**离线**双向自测(不碰设备)：
#   T2.5b：@sushd 的 root 腿没落地时，CLOSEFALLBACK=1 才走"Termux 上敲 w450_close.sh"的替代腿；
#   T5   ：复位后**复读**那批固定名(条数由本自测从 T5_FIX 现数，不写死——写死的那句"11 个"在 10-22 加 FDKA 三件时就滞后的；
#         例 97 第二次实测：rm 之后写者把名字又建回来)。
#   十格(带日期登记，逐格都是"正反各一"而不是只验正向)：
#     ①root 腿已落地 ⇒ 明说"不需要替代腿"，且**一个 adb push/一次敲键都不许有**；
#     ②没落地＋没给开关 ⇒ 必须把"名单文件是否还在＝未知"打在明面，同样零敲键(默认关＝不自动操作 UI)；
#     ③没落地＋CLOSEFALLBACK=1＋两端 md5 相符＋读数里有 rm_allow_rc=0 ⇒ 打 [OK]，且敲键序列必须是
#       "起 Termux 1 次 / input text 2 次(su、sh<路径>) / keyevent 66 两次"；
#     ④两端 md5 不符 ⇒ 打"一个键都不敲"，并且**真的**零敲键、零 am start(这条的牙在命令日志里，不在文案里)；
#     ⑤md5 相符但读数里没有 rm_allow_rc=0 ⇒ 打 [!] 且明说"是否删掉＝未知"；
#     ⑥T5：一个都不在 ⇒ [OK]，且**打印的条数要我用独立算法现数**(例 91：不许从文案里正则回数)；
#     ⑦T5：第一次在、再删后不在 ⇒ 两条都要出现(先"再删一次"后"[OK] 复读")；
#     ⑧T5：再删后仍在 ⇒ 必须 [!] 仍在(不许把"仍在"写成绿)；
#     ⑨静态牙：删与复证同一个生产者(T5_CHK 用两次、不许再手抄 grep 模式)；
#     ⑩静态牙：T5_FIX 每个名字都必须也在 T3_RM 里(复位前那张表漏一个 ⇒ 复读就是白读)，
#       且 ksu_args.txt / w450_close.sh 这次加进去的两条确实在。
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
W=$(mktemp -d)
nchk=0; fail=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

echo "=== 0) 切片：两块都要切到，且切片里带着自己的牙 ==="
awk '/=== T2\.5b\)/{f=1} /=== T2\.6\)/{f=0} f' kmod/w161_teardown.sh > "$W/b25.sh"
awk '/=== T5\)/{f=1} f' kmod/w161_teardown.sh > "$W/b5.sh"
[ -s "$W/b25.sh" ] || { echo "[x] 没切出 T2.5b ⇒ 起点锚失效"; exit 1; }
[ -s "$W/b5.sh" ]  || { echo "[x] 没切出 T5 ⇒ 起点锚失效"; exit 1; }
grep -q 'md5sum kmod/w450_close.sh' "$W/b25.sh" || { echo "[x] T2.5b 切片里没有两端 md5 闸 ⇒ 终点锚在闸之前"; exit 1; }
grep -q "rm_allow_rc=0"             "$W/b25.sh" || { echo "[x] T2.5b 切片里没有末端读数 ⇒ 这条腿没有证人"; exit 1; }
grep -q 'w135_off.sh'               "$W/b25.sh" && { echo "[x] T2.5b 切片把 T2 的卸载腿吞进来了 ⇒ 终点锚失效"; exit 1; }
grep -q 'T5_LEFT2=$(T5_CHK)'        "$W/b5.sh"  || { echo "[x] T5 切片没有第二次复读 ⇒ 只有一次点读(例 117)"; exit 1; }
grep -q "grep -aE 'dmesg"           "$W/b5.sh"  && { echo "[x] T5 里又手抄了一条 grep 模式 ⇒ 两个生产者(例 120)"; exit 1; }
echo "  切片行数：T2.5b=$(wc -l < "$W/b25.sh") T5=$(wc -l < "$W/b5.sh")"

# 独立现数 T5_FIX 的条数与名单(不从脚本输出的文案里回取)
T5_LINE=$(grep -m1 '^T5_FIX=' kmod/w161_teardown.sh)
T5_VAL=$(printf '%s' "${T5_LINE#*\"}" | sed 's/"$//')
set -- $T5_VAL; EXP_N=$#
T3RM=$(grep -m1 "^T3_RM=" kmod/w161_teardown.sh | sed "s/^T3_RM='//; s/'$//")
echo "  T5_FIX 独立现数：$EXP_N 个 ⇒ $T5_VAL"

run25() { # $1=tag $2=ADB_CLEAN_OK $3=CF(1|0) $4=devmd5(ok|bad) $5=report(has|none)
    : > "$W/calls_$1.log"
    (
        cd "$ROOT" || exit 1
        CASE=$1; CO=$2; CF=$3; DM=$4; RP=$5   # ★CASE 单独存名：桩函数里的 $1 是**命令串**不是格子名(第一版把日志名写成了整条命令 ⇒ 计数恒 0)
        L_MD5=$(md5sum kmod/w450_close.sh | cut -c1-32)
        A() {
            printf 'A|%s\n' "$1" >> "$W/calls_$CASE.log"
            case "$1" in
                *'md5sum /data/local/tmp/w450_close.sh'*)
                    [ "$DM" = bad ] && { echo 'ffffffffffffffffffffffffffffffff  x'; return; }
                    printf '%s  x\n' "$L_MD5"; return;;
                *grep*rm_allow_rc*) [ "$RP" = has ] && { echo 'rm_allow_rc=0'; }; return;;
                *'cat /sdcard/w450_close.txt'*) [ "$RP" = has ] && { echo 'UMOUNT_RC=0'; echo 'rm_allow_rc=0'; echo 'ALLOW_GONE=1'; }; return;;
                *chmod*) return;;
            esac
            echo STUB
        }
        adb() { printf 'ADB|%s\n' "$*" >> "$W/calls_$CASE.log"; return 0; }
        sleep() { :; }
        ADB_CLEAN_OK=$CO
        if [ "$CF" = 1 ]; then CLOSEFALLBACK=1; else unset CLOSEFALLBACK; fi
        source "$W/b25.sh" > "$W/out_$1.txt" 2>&1
    )
    echo "----- case 25-$1 (clean_ok=$2 cf=$3 md5=$4 report=$5) -----"
    sed 's/^/    /' "$W/out_$1.txt"
}
N_INPUT() { grep -ac '^A|input ' "$W/calls_$1.log" | tr -dc '0-9'; }
N_KEY()   { grep -ac '^A|input keyevent' "$W/calls_$1.log" | tr -dc '0-9'; }
N_TEXT()  { grep -ac '^A|input text' "$W/calls_$1.log" | tr -dc '0-9'; }
N_START() { grep -ac '^A|am start' "$W/calls_$1.log" | tr -dc '0-9'; }
N_PUSH()  { grep -ac '^ADB|push' "$W/calls_$1.log" | tr -dc '0-9'; }   # ★桩记的是 `$*`(=push 源 目标)，程序名本身不在里面

run25 landed 1 0 ok has
chk "①root 腿已落地 ⇒ 明说『不需要替代腿』" "$(grep -aq '不需要替代腿' "$W/out_landed.txt" && echo 1 || echo 0)"
chk "①且一次 push/敲键都没有(push=$(N_PUSH landed) 键=$(N_KEY landed))" "$([ "$(N_PUSH landed)" = 0 ] && [ "$(N_INPUT landed)" = 0 ] && echo 1 || echo 0)"
run25 nodefault 0 0 ok has
chk "②没给 CLOSEFALLBACK ⇒ 把风险打在明面" "$(grep -aq '名单文件是否还在＝未知' "$W/out_nodefault.txt" && echo 1 || echo 0)"
chk "②默认关：零敲键零起 app(键=$(N_KEY nodefault) am start=$(N_START nodefault))" "$([ "$(N_INPUT nodefault)" = 0 ] && [ "$(N_START nodefault)" = 0 ] && echo 1 || echo 0)"
run25 fallback 0 1 ok has
chk "③替代腿落地 ⇒ 打 [OK]" "$(grep -aq '替代腿落地' "$W/out_fallback.txt" && echo 1 || echo 0)"
chk "③敲键序列＝起 Termux 1 次/input text 2 次/keyevent 2 次(实得 $(N_START fallback)/$(N_TEXT fallback)/$(N_KEY fallback))" \
    "$([ "$(N_START fallback)" = 1 ] && [ "$(N_TEXT fallback)" = 2 ] && [ "$(N_KEY fallback)" = 2 ] && echo 1 || echo 0)"
chk "③那条带 rm 的件是先 push 再核 md5 才敲(它没有别的来源) ⇒ push=1" "$([ "$(N_PUSH fallback)" = 1 ] && echo 1 || echo 0)"
chk "③正向走了就不许再打『没给 CLOSEFALLBACK』那句(两条分支文案不许串)" "$(grep -aqv '没给 CLOSEFALLBACK' "$W/out_fallback.txt" && echo 1 || echo 0)"
run25 badmd5 0 1 bad has
chk "④md5 不符 ⇒ 打『一个键都不敲』" "$(grep -aq '一个键都不敲' "$W/out_badmd5.txt" && echo 1 || echo 0)"
chk "④而且**真的**零敲键零起 app(键=$(N_INPUT badmd5) am start=$(N_START badmd5))——牙在日志不在文案" "$([ "$(N_INPUT badmd5)" = 0 ] && [ "$(N_START badmd5)" = 0 ] && echo 1 || echo 0)"
chk "④反夹具对质：坏 md5 那格与好 md5 那格的输出必须不同(否则两格测的是同一件事)" "$([ "$(grep -ac '替代腿落地' "$W/out_badmd5.txt" | tr -dc '0-9')" = 0 ] && echo 1 || echo 0)"
run25 noread 0 1 ok none
chk "⑤md5 相符但读数里没 rm_allow_rc=0 ⇒ [!] 是否删掉＝未知" "$(grep -aq '替代腿没读到 rm_allow_rc=0' "$W/out_noread.txt" && echo 1 || echo 0)"
chk "⑤这一格键确实敲了(不是腿没跑) ⇒ input text=$(N_TEXT noread)" "$([ "$(N_TEXT noread)" = 2 ] && echo 1 || echo 0)"

run5() { # $1=tag $2=mode clean|then_clean|always
    : > "$W/calls5_$1.log"; echo 0 > "$W/nc_$1"
    (
        cd "$ROOT" || exit 1
        CASE=$1; MD=$2
        A() {
            printf 'A|%s\n' "$1" >> "$W/calls5_$CASE.log"
            case "$1" in
                'for f in '*)
                    n=$(cat "$W/nc_$CASE"); echo $((n+1)) > "$W/nc_$CASE"
                    [ "$MD" = clean ] && { echo ""; return; }
                    if [ "$MD" = then_clean ] && [ "$n" -ge 1 ]; then echo ""; return; fi
                    echo /data/local/tmp/dmesg2.log; return;;
                'rm -f '*|*'rm -f /data/local/tmp/'*) echo RM_OK; return;;
            esac
            echo STUB
        }
        adb() { printf 'ADB|%s\n' "$*" >> "$W/calls5_$CASE.log"; return 0; }
        sleep() { :; }
        source "$W/b5.sh" > "$W/out5_$1.txt" 2>&1
    )
    echo "----- case 5-$1 (mode=$2) -----"
    sed 's/^/    /' "$W/out5_$1.txt"
}
run5 clean clean
OKN=$(grep -oE '复读：[0-9]+ 个固定名' "$W/out5_clean.txt" | grep -oE '[0-9]+' | tail -1)
chk "⑥全不在 ⇒ [OK]，且打印的条数($OKN)＝我独立现数的($EXP_N)" "$([ "$OKN" = "$EXP_N" ] && grep -aq '一个都不在' "$W/out5_clean.txt" && echo 1 || echo 0)"
chk "⑥这一格 rm 一次都没调用(没残留就不许删)" "$([ "$(grep -ac 'rm -f' "$W/calls5_clean.log" | tr -dc '0-9')" = 0 ] && echo 1 || echo 0)"
run5 again then_clean
chk "⑦第一次在 ⇒ 先打『再删一次』，第二次复读打 [OK] 删净" "$(grep -aq '再删一次' "$W/out5_again.txt" && grep -aq '现在都删净了' "$W/out5_again.txt" && echo 1 || echo 0)"
chk "⑦那条 rm 删的是读回来的名字本身(不是手抄的另一个名单)" "$(grep -aq 'rm -f /data/local/tmp/dmesg2.log' "$W/calls5_again.log" && echo 1 || echo 0)"
chk "⑦复证又读了一次(T5_CHK 被调 2 次，实得 $(grep -ac '^A|for f in ' "$W/calls5_again.log" | tr -dc '0-9'))" "$([ "$(grep -ac '^A|for f in ' "$W/calls5_again.log" | tr -dc '0-9')" = 2 ] && echo 1 || echo 0)"
run5 stuck always
chk "⑧再删后仍在 ⇒ 必须 [!] 仍在(不许把仍在写成绿)" "$(grep -aq '\[!\] 仍在' "$W/out5_stuck.txt" && echo 1 || echo 0)"
chk "⑧且这一格没打『现在都删净了』" "$([ "$(grep -ac '现在都删净了' "$W/out5_stuck.txt" | tr -dc '0-9')" = 0 ] && echo 1 || echo 0)"

echo "=== 8b) pbin 那条登记(第 32 发抓出来的假读数：目录不存在时「ls 2>&1 | wc -l」把报错行数成 1 件) ==="
awk '/^PBIN_STATE=\$\(A /{f=1} /pbin 里剩/{f=1} f && /^fi$/{print; f=0; next} f' kmod/w161_teardown.sh > "$W/bp.sh"
[ "$(wc -l < "$W/bp.sh")" -ge 6 ] || { echo "[x] pbin 那块没切全(行数=$(wc -l < "$W/bp.sh"))"; exit 1; }
grep -q '2>&1 | wc -l' "$W/bp.sh" && { echo "[x] pbin 那块还在数 stderr"; exit 1; }
run_pb() { # $1=tag $2=远端返回(设备侧目录状态)
    (
        cd "$ROOT" || exit 1
        CASE=$1; OUT=$2
        A() { printf '%s\n' "$OUT"; }
        source "$W/bp.sh" > "$W/outpb_$1.txt" 2>&1
    )
    sed 's/^/    /' "$W/outpb_$1.txt"
}
run_pb gone GONE
run_pb three 3
run_pb zero 0
chk "8b①目录已不在 ⇒ 打『目录已不在』且**不许**出现『剩 1 件』(旧写法就在这里造出假读数)" \
    "$(grep -aq '目录已不在' "$W/outpb_gone.txt" && ! grep -aq '剩 1 件' "$W/outpb_gone.txt" && echo 1 || echo 0)"
chk "8b②里面有 3 件 ⇒ 如实打『剩 3 件』(不是把 GONE 分支误当默认)" "$(grep -aq '剩 3 件' "$W/outpb_three.txt" && echo 1 || echo 0)"
chk "8b③空目录 ⇒ 打『剩 0 件』(0 与『不在』是两种读数，不许混)" "$(grep -aq '剩 0 件' "$W/outpb_zero.txt" && echo 1 || echo 0)"
chk "8b④反夹具：把 stderr 一起数的旧写法喂 GONE 会得 1 ⇒ 证明这一格测的就是这个坑" \
    "$([ "$(printf '%s\n' 'ls: /data/local/tmp/pbin: No such file or directory' | wc -l | tr -dc '0-9')" = 1 ] && echo 1 || echo 0)"

echo "=== 9) 静态牙：默认关 + 名单同源 ==="
chk "⑨开关默认关(读回是 \${CLOSEFALLBACK:-0} 而不是 :-1)" "$(grep -q 'CLOSEFALLBACK:-0' kmod/w161_teardown.sh && echo 1 || echo 0)"
TYPED=$(sed -n 's/.*input text \([^"]*\)".*/\1/p' "$W/b25.sh" | tr '\n' '|')
chk "⑨敲进去的那一串里没有重定向号(§6.366① 输入法会吃 >；实得 [$TYPED])" \
    "$(printf '%s' "$TYPED" | grep -q '>' && echo 0 || echo 1)"
chk "⑨正对照：这条断言有牙——把敲进去的串换成带 > 的形状，它必须变红" \
    "$(printf '%s' "$TYPED" | sed 's|sh%s|sh >eat|' | grep -q '>' && echo 1 || echo 0)"
chk "⑨w450_close.sh 自己把读数写进文件(exec > 在脚本内部，不靠敲键)" "$(grep -q 'exec >/sdcard/w450_close.txt' kmod/w450_close.sh && echo 1 || echo 0)"
#   ★第 32 发上机抓到的两条(那条腿本身跑通了，但读数缺一块 / 脚印漏一个)：
chk "⑨w450_close.sh 里 getenforce 走绝对路径(裸写 ⇒ root 壳 PATH 没有 ⇒ enf= 是空的，§6.368③)" \
    "$(grep -q '/system/bin/getenforce' kmod/w450_close.sh && ! grep -qE '\$\((getenforce|umount)' kmod/w450_close.sh && echo 1 || echo 0)"
chk "⑨正对照：把绝对路径拆掉，上面那条必须红" \
    "$(sed 's|/system/bin/getenforce|getenforce|' kmod/w450_close.sh | grep -qE '\$\(getenforce' && echo 1 || echo 0)"
chk "⑨这条腿删的不止名单文件，还删 stage cp 进 /data/adb 的那份可执行脚印(ksud)，并留 rm 的 rc 读数" \
    "$(grep -q 'rm -f /data/adb/ksud' kmod/w450_close.sh && grep -q 'rm_ksud_rc' kmod/w450_close.sh && echo 1 || echo 0)"
MISS=""
for f in $T5_VAL; do
    case " $T3RM " in *" /data/local/tmp/$f "*) : ;; *) MISS="$MISS $f";; esac
done
chk "⑩T5_FIX 的 $EXP_N 个名字全在 T3_RM 里(缺：${MISS:-无})" "$([ -z "$MISS" ] && echo 1 || echo 0)"
chk "⑩这次新加的两条(ksu_args.txt / w450_close.sh)确实在 T3_RM" "$(printf '%s' "$T3RM" | grep -q '/data/local/tmp/ksu_args.txt' && printf '%s' "$T3RM" | grep -q '/data/local/tmp/w450_close.sh' && echo 1 || echo 0)"
T3CHECK=$(grep -m1 '^T3_LEFT=' kmod/w161_teardown.sh)
chk "⑩T3 的复证也是从名单派生(同一串)，没另写模式" "$(printf '%s' "$T3CHECK" | grep -q 'for f in \$T3_RM \$T3_GLOB' && echo 1 || echo 0)"

echo
[ "$fail" = 0 ] && echo "=== run_teardownlegs 自测 PASS($nchk 项，条数由 chk 自数) ===" || echo "=== FAIL($nchk 项里有红) ==="
echo "临时件留在 $W(手看再删)"
[ "$fail" = 0 ]
