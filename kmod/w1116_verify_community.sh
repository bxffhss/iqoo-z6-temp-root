#!/bin/bash
# w1116_verify_community.sh —— 在构建机上验"社区模块的 sepolicy.rule 能不能原样进这台机的活策略"，
#   产出一行一键的死数字给链读。与 w1109_verify_remote.sh 的区别＝**判据换掉了**：
#     w1109 那批是我们自己写的 3 条（全新 key，期望 +3/−0）；
#     这批是 LSPosed/Zygisk Next 原文里"这台机能表达的"9 行 ⇒ 其中 4 行会**并进厂商已有的节点**（MERGED），
#     于是三元组行差分会出现"旧写法被删、新写法被加"——**那不是削弱，是加宽**。
#   ⇒ 所以这一版把判据写成机械的"零削弱"证明：每一条被去掉的写法，同一个 key 必须以"旧权限全都在新权限里"的形式回来。
# 用法（远端）：bash w1116_verify_community.sh <pol 名> <rules 名>
#   输出键：ORIG_MD5= RT_ADDED= RT_REMOVED= INSERTED= MERGED= RULES_IN_FILE= C_ADDED= C_REMOVED=
#           ZERO_WEAKEN= NEW_MD5= NEW_BYTES= VERDICT=ok|fail
set -u
cd /home/lucy || exit 9
POL=${1:-pol.orig}; RULES=${2:-rules9.txt}
BIN=/home/lucy/w1104_host
R() { grep -v '^DUMP_' "$1" | sort; }
[ -f "$POL" ] || { echo "缺 $POL"; echo VERDICT=fail; exit 8; }
[ -f "$RULES" ] || { echo "缺 $RULES"; echo VERDICT=fail; exit 8; }
[ -x "$BIN" ] || { echo "缺可执行的 $BIN"; echo VERDICT=fail; exit 8; }

md5sum "$POL" | cut -d' ' -f1 | sed 's/^/ORIG_MD5=/'
"$BIN" dump "$POL" A.txt >/dev/null 2>&1 || { echo "dump 失败"; echo VERDICT=fail; exit 7; }
"$BIN" rt "$POL" rt.pol >rt.log 2>&1 || { echo "rt 失败"; echo VERDICT=fail; exit 7; }
"$BIN" dump rt.pol B.txt >/dev/null 2>&1
echo "RT_ADDED=$(comm -13 <(R A.txt) <(R B.txt) | grep -ac .)"
echo "RT_REMOVED=$(comm -23 <(R A.txt) <(R B.txt) | grep -ac .)"

"$BIN" delta "$POL" new.pol "$RULES" >delta.log 2>&1 || { grep -a '^ERROR:' delta.log; echo VERDICT=fail; exit 8; }
sed -n 's/^INSERTED=\([0-9]*\).*/INSERTED=\1/p' delta.log
sed -n 's/^.*MERGED=\([0-9]*\).*/MERGED=\1/p' delta.log
sed -n 's/^.*RULES_IN_FILE=\([0-9]*\).*/RULES_IN_FILE=\1/p' delta.log
"$BIN" dump new.pol C.txt >/dev/null 2>&1
echo "C_ADDED=$(comm -13 <(R A.txt) <(R C.txt) | grep -ac .)"
echo "C_REMOVED=$(comm -23 <(R A.txt) <(R C.txt) | grep -ac .)"

# ★零削弱的机械证明：每一条"被去掉的写法"，同 key 的新写法必须包含它全部的权限
ZW=0
while IFS= read -r L; do
    [ -n "$L" ] || continue
    K=$(echo "$L" | cut -d' ' -f1-3)
    NEWL=$(R C.txt | grep -F "$K ")
    [ -n "$NEWL" ] || { echo "  WEAKEN key=[$K] 新的写法根本没回来"; ZW=$((ZW+1)); continue; }
    MISS=$(comm -23 <(echo "$L" | cut -d' ' -f4 | tr ',' '\n' | sort) \
                    <(echo "$NEWL" | cut -d' ' -f4 | tr ',' '\n' | sort) | tr -d '\n ')
    if [ -n "$MISS" ]; then echo "  WEAKEN key=[$K] 丢了权限=$MISS"; ZW=$((ZW+1)); fi
done < <(comm -23 <(R A.txt) <(R C.txt))
echo "ZERO_WEAKEN=$ZW (必须＝0)"

md5sum new.pol | cut -d' ' -f1 | sed 's/^/NEW_MD5=/'
echo "NEW_BYTES=$(wc -c < new.pol)"
A1=$(comm -13 <(R A.txt) <(R B.txt) | grep -c .); B1=$(comm -23 <(R A.txt) <(R B.txt) | grep -c .)
if [ "$A1" = 0 ] && [ "$B1" = 0 ] && [ "$ZW" = 0 ]; then echo VERDICT=ok; else echo VERDICT=fail; fi
