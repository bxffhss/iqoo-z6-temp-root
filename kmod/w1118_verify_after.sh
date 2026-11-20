#!/bin/bash
# w1118_verify_after.sh —— 装完之后那一份(`pol.after`)对厂商那一份(`A.txt`＝[4/6] 里 dump 过的活策略)的差分。
#   ★为什么单独要一支：装载后的判据与装载前**不是同一件事**——装载前证的是"我构造的图长这样"，
#   装载后证的是"**内核实际生效的那张表**长这样"。两者数字必须各算各的，不能拿前者顶后者(例 155/187 同族)。
#   判据＝AF_ADDED/AF_REMOVED 与装载前那对数字**逐位相同**，且 AF_ZW(零削弱)＝0；AFTER_NODES 当旁证。
# 用法（远端，工作目录里要有 A.txt）：bash w1118_verify_after.sh <pol.after 路径>
set -u
cd /home/lucy || exit 9
AFT=${1:-pol.after}
BIN=/home/lucy/w1104_host
R() { grep -v '^DUMP_' "$1" | sort; }
[ -f "$AFT" ] || { echo "缺 $AFT"; echo AF_VERDICT=fail; exit 8; }
[ -f A.txt ] || { echo "缺 A.txt(装载前那份活策略的 dump) ⇒ 无从对比"; echo AF_VERDICT=fail; exit 8; }
"$BIN" dump "$AFT" D.txt >dump.err 2>&1 || { echo "dump(after) 失败：$(head -2 dump.err)"; echo AF_VERDICT=fail; exit 7; }
echo "AFTER_NODES=$(sed -n 's/^DUMP_NODES=\([0-9]*\).*/\1/p' D.txt)"
md5sum "$AFT" | cut -d' ' -f1 | sed 's/^/AFTER_MD5=/'
echo "AF_ADDED=$(comm -13 <(R A.txt) <(R D.txt) | grep -ac .)"
echo "AF_REMOVED=$(comm -23 <(R A.txt) <(R D.txt) | grep -ac .)"
ZW=0
while IFS= read -r L; do
    [ -n "$L" ] || continue
    K=$(echo "$L" | cut -d' ' -f1-3)
    NEWL=$(R D.txt | grep -F "$K ")
    [ -n "$NEWL" ] || { echo "  AF_WEAKEN key=[$K] 新写法没回来"; ZW=$((ZW+1)); continue; }
    MISS=$(comm -23 <(echo "$L" | cut -d' ' -f4 | tr ',' '\n' | sort) \
                    <(echo "$NEWL" | cut -d' ' -f4 | tr ',' '\n' | sort) | tr -d '\n ')
    [ -n "$MISS" ] && { echo "  AF_WEAKEN key=[$K] 丢了权限=$MISS"; ZW=$((ZW+1)); }
done < <(comm -23 <(R A.txt) <(R D.txt))
echo "AF_ZW=$ZW (必须＝0)"
comm -13 <(R A.txt) <(R D.txt) | head -10 | sed 's/^/  AFADD /'
if [ "$ZW" = 0 ]; then echo AF_VERDICT=ok; else echo AF_VERDICT=fail; fi
