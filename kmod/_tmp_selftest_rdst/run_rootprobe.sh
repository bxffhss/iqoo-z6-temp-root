#!/usr/bin/env bash
# run_rootprobe.sh —— 给 w161_teardown.sh 的 T2.6(ROOTPROBE 腿)做**双向离线自测**（不碰设备）。
#   四格：①默认关⇒一条 adb 都不发、开关行读回"跳过"；②开⇒push+fire+落盘三件都有产物；
#         ③"不加就坏"的反例：WAITFOR 不到 DONE ⇒ 必须打"没测到"且**不产出空存证件**；
#         ④md5 不符 ⇒ 硬闸：不许 fire(这条腿里带 rm)。
#   规矩(例 88/105/116)：每个"形状词"都要有实现动作＋读回产物；自测必须含"这一腿真的改了"那一格。
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
W=$(mktemp -d)
mkdir -p "$W/kmod/w103_evidence"
cp kmod/w407_rootprobe.sh "$W/kmod/"
awk '/=== T2.6/{f=1} /=== T2\.7\)/{f=0} f' kmod/w161_teardown.sh > "$W/block.sh"
[ -s "$W/block.sh" ] || { echo "[x] 没能切出 T2.6 那段 ⇒ 锚点失效，别继续测"; exit 1; }
# ★切片的**边界也要有牙**：T2.7 会真的 `adb pull` 并往 kmod/w103_evidence 写文件，绝不能混进这段离线测试。
grep -q 'w407_rootprobe.sh' "$W/block.sh" || { echo "[x] 切片里没有 w407 那条腿 ⇒ 起点锚错了"; exit 1; }
grep -q 'T2\.7' "$W/block.sh" && { echo "[x] 切片把 T2.7 也吞进来了(它会做真 adb pull) ⇒ 终点锚失效，离线自测不许碰设备/存证目录"; exit 1; }
echo "切片行数=$(wc -l < "$W/block.sh")"
fail=0
LM_REAL=$(md5sum kmod/w407_rootprobe.sh | cut -c1-32)

run_case() { # $1=tag $2=ROOTPROBE值 $3=WFF_RC $4=MD5是否相符
    local tag=$1 rp=$2 wff=$3 good=$4
    : > "$W/log_$tag.txt"
    (
        cd "$W" || exit 1
        A() { echo "ADB[$1]" >> "$W/log_$tag.txt"
            case "$1" in
                *md5sum*) if [ "$good" = 1 ]; then echo "$LM_REAL"; else echo 'deadbeefdeadbeefdeadbeefdeadbeef'; fi ;;
                'cat /data/local/tmp/w407_rootprobe.out') printf '%s\n' "=== ROOTPROBE up=2999 uid=0 mod=1 enf=Permissive ===" "   ★总行数=877" '   [com.suw.manager] com.suw.manager 10342 0 0 0 -1 0' "   ★删之后=ls: /data/local/tmp/kd: No such file or directory" ;;
                *) echo STUB ;;
            esac; }
        fire() { echo "FIRE[$1]" >> "$W/log_$tag.txt"; }
        adb() { echo "ADBRAW[$*]" >> "$W/log_$tag.txt"; }
        WAITFOR() { echo "WAITFOR[$1|$3]" >> "$W/log_$tag.txt"; return "$wff"; }
        # ★必须 source：`bash block.sh` 是新进程，继承不到上面这些桩函数(第一版就是这样全红的)
        ROOTPROBE="$rp"
        source "$W/block.sh" > "$W/out_$tag.txt" 2>&1
    )
    echo "----- case $tag (ROOTPROBE='${rp:-}' wff=$wff good=$good) -----"
    sed 's/^/    /' "$W/out_$tag.txt"
}
chk() { # $1=说明 $2=条件表达式(字符串真值)
    if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi
}

run_case off "" 1 1
run_case on 1 0 1
run_case nowait 1 1 1
run_case badmd5 1 0 0

N=$(grep -c 'w407' "$W/log_off.txt")
chk "①默认关：一条 w407 相关 adb 都不发(行数=$N)" "$([ "$N" = 0 ] && echo 1 || echo 0)"
chk "①默认关：读回那行说'跳过＝收尾形状逐字不变'" "$(grep -aq '未给 ROOTPROBE' "$W/out_off.txt" && echo 1 || echo 0)"

chk "②开：有 push(ADBRAW 里出现 w407_rootprobe.sh)" "$(grep -aq 'ADBRAW\[push kmod/w407_rootprobe.sh' "$W/log_on.txt" && echo 1 || echo 0)"
chk "②开：fire 的是 @sushd 那条 root 腿" "$(grep -aq 'FIRE\[@sushd:/data/local/tmp/w407_rootprobe.sh' "$W/log_on.txt" && echo 1 || echo 0)"
chk "②开：两端 md5 读回＝本机 $LM_REAL" "$(grep -aq "两端 md5=$LM_REAL" "$W/out_on.txt" && echo 1 || echo 0)"
FILES=$(ls "$W/kmod/w103_evidence" 2>/dev/null | grep -c w407_rootprobe_)
chk "②开：存证件真的落地(数到 $FILES 份)" "$([ "$FILES" -ge 1 ] && echo 1 || echo 0)"
INFILE=$(cat "$W"/kmod/w103_evidence/w407_rootprobe_*.txt 2>/dev/null | grep -c '★总行数=877')
chk "②开：证件**内容**里有读数(不是只建了个空文件)" "$([ "$INFILE" -ge 1 ] && echo 1 || echo 0)"

chk "③等不到 DONE：打'没测到'且不许当读数" "$(grep -aq '探针没到 DONE' "$W/out_nowait.txt" && echo 1 || echo 0)"
N2=$(grep -c '★总行数=877' "$W/out_nowait.txt")
chk "③等不到 DONE：那组读数没被当成结论打印(命中=$N2)" "$([ "$N2" = 0 ] && echo 1 || echo 0)"

chk "④md5 不符：打出不符并硬闸" "$(grep -aq '不是本机这份' "$W/out_badmd5.txt" && echo 1 || echo 0)"
chk "④md5 不符：**没有 fire**(这条腿带 rm)" "$(grep -aq 'FIRE\[@sushd:/data/local/tmp/w407_rootprobe.sh' "$W/log_badmd5.txt" && echo 0 || echo 1)"
FILES_END=$(ls "$W/kmod/w103_evidence" 2>/dev/null | grep -c w407_rootprobe_)
chk "③④都没往存证目录写东西(全程只 case② 产出 1 份，现＝$FILES_END)" "$([ "$FILES_END" = 1 ] && echo 1 || echo 0)"

echo
[ "$fail" = 0 ] && echo "=== run_rootprobe 自测 PASS(12 项断言) ===" || echo "=== FAIL ==="
echo "临时件留在 $W(要手看再删；里面有 4 份 out_/log_)"
exit "$fail"
