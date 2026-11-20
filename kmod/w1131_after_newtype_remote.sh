#!/bin/bash
# w1131_after_newtype_remote.sh —— 第 95 发装完之后那一份(`pol.after`＝**内核自己序列化出来的活策略**)的尺。
#   ★为什么装载前的 w1129 不算数、这一支必须单独有(§6.516 那一族)：w1129 证的是"**我构造的图**长这样"，
#     这一支证的是"**内核实际生效的那张表**长这样"。#234 的问题("运行期装载收不收变长的 type 表")
#     只有后者能答：内核可能收下 write() 却在 policydb_read 里把表读短/读歪，那 `load` 的 rc=0 就是假绿。
#   ★尺子全部是结构尺，不用 md5 当语义证人(11-03 立的那条口径：空 delta 往返**字节数相同但 md5 不同**，
#     md5 只用来对"两端是不是同一个件"，不用来回答"内容对不对")。
#   三把尺：
#     ①AF_VS_NEW_*：pol.after 的 avtab 三元组 vs **我们推下去那份 new.pol** ⇒ 必须 0/0(内核没改也没丢)；
#     ②AF_TMAP_VS_NEW_*：ATAR 表逐行(按值序) vs new.pol ⇒ 必须 0/0(表尾那两行真在活策略里)；
#     ③AF_TMAP_VS_VENDOR_MISSING ＋ AF_ZW：厂商那 3645 行一行不少，且每一条被去掉的写法同 key 必须
#       以"旧权限⊆新权限"的形式回来 ⇒ 装载没有削弱任何一条(零削弱)。
# 用法(远端 /home/lucy)：bash w1131_after_newtype_remote.sh <bin> <pol.after> <new.pol> <pol.orig> <new的md5> <orig的md5>
# 输出键：BIN_MD5= AF_MD5= AF_BYTES= AF_TYPES= AF_NODES= AF_POLICYVERS= NEW_MD5_REMOTE= ORIG_MD5_REMOTE=
#         AF_VS_NEW_ADDED= AF_VS_NEW_REMOVED= AF_TMAP_VS_NEW_MISSING= AF_TMAP_VS_NEW_EXTRA=
#         AF_TMAP_VS_VENDOR_MISSING= AF_ZW= AF_PROBE_ROW= AF_UNUSED_ROW= AF_VERDICT=
set -u
cd /home/lucy || exit 9
BIN=${1:?bin}; AFT=${2:?pol.after}; NEWP=${3:?new.pol}; VEND=${4:?pol.orig}
WNEW=${5:?new 的 md5}; WVEND=${6:?厂商的 md5}
R() { grep -v '^DUMP_' "$1" | sort; }
T() { grep -a '^TMAP ' "$1"; }
for f in "$BIN" "$AFT" "$NEWP" "$VEND"; do
    [ -f "$f" ] || { echo "[x] 缺 $f ⇒ 这一支没有对比面，装载后那一侧记未测(不许拿 0 当结论)"; echo AF_VERDICT=missing; exit 8; }
done
GNEW=$(md5sum "$NEWP" | cut -d' ' -f1); GVEND=$(md5sum "$VEND" | cut -d' ' -f1)
echo "BIN_MD5=$(md5sum "$BIN" | cut -d' ' -f1) NEW_MD5_REMOTE=$GNEW ORIG_MD5_REMOTE=$GVEND"
[ "$GNEW" = "$WNEW" ] || { echo "[x] 远端那份 new.pol 不是链推下去的那份 ⇒ 比了也白比"; echo AF_VERDICT=missing; exit 8; }
[ "$GVEND" = "$WVEND" ] || { echo "[x] 远端那份 pol.orig 不是厂商件"; echo AF_VERDICT=missing; exit 8; }

rm -f FA.txt TA.txt FN.txt TN.txt TV.txt
"$BIN" dump "$AFT"  FA.txt >/dev/null 2>&1 || { echo "[x] dump(pol.after) 失败"; echo AF_VERDICT=fail; exit 7; }
"$BIN" dump "$NEWP" FN.txt >/dev/null 2>&1 || { echo "[x] dump(new.pol) 失败"; echo AF_VERDICT=fail; exit 7; }
"$BIN" dump "$VEND" TV.txt >/dev/null 2>&1 || { echo "[x] dump(pol.orig) 失败"; echo AF_VERDICT=fail; exit 7; }
"$BIN" tmap "$AFT"  TA.txt >/dev/null 2>&1 || { echo "[x] tmap(pol.after) 失败"; echo AF_VERDICT=fail; exit 7; }
"$BIN" tmap "$NEWP" TN.txt >/dev/null 2>&1 || { echo "[x] tmap(new.pol) 失败"; echo AF_VERDICT=fail; exit 7; }
echo "AF_MD5=$(md5sum "$AFT" | cut -d' ' -f1) AF_BYTES=$(wc -c < "$AFT") AF_TYPES=$(sed -n 's/^DUMP_TYPES=\([0-9]*\).*/\1/p' FA.txt) AF_NODES=$(sed -n 's/^DUMP_NODES=\([0-9]*\).*/\1/p' FA.txt) AF_POLICYVERS=$(sed -n 's/^DUMP_POLICYVERS=\([0-9]*\).*/\1/p' FA.txt)"

echo "AF_VS_NEW_ADDED=$(comm -13 <(R FN.txt) <(R FA.txt) | grep -ac .) AF_VS_NEW_REMOVED=$(comm -23 <(R FN.txt) <(R FA.txt) | grep -ac .)"
comm -13 <(R FN.txt) <(R FA.txt) | head -6 | sed 's/^/  ADDVSNEW /'
comm -23 <(R FN.txt) <(R FA.txt) | head -6 | sed 's/^/  DELVSNEW /'
echo "AF_TMAP_VS_NEW_MISSING=$(comm -23 <(T TN.txt) <(T TA.txt) | grep -ac .) AF_TMAP_VS_NEW_EXTRA=$(comm -13 <(T TN.txt) <(T TA.txt) | grep -ac .)"
comm -23 <(T TN.txt) <(T TA.txt) | head -4 | sed 's/^/  GONE /'
comm -13 <(T TN.txt) <(T TA.txt) | head -4 | sed 's/^/  ADDED /'
echo "AF_TMAP_VS_VENDOR_MISSING=$(comm -23 <(T TV.txt) <(T TA.txt) | grep -ac .)"
comm -23 <(T TV.txt) <(T TA.txt) | head -4 | sed 's/^/  GONEVENDOR /'
grep -a ' z6_probe_file ' TA.txt | head -1 | sed 's/^/AF_PROBE_ROW=/'
grep -a ' z6_unused_file ' TA.txt | head -1 | sed 's/^/AF_UNUSED_ROW=/'

# ★零削弱(对厂商那份)：机械证明，不靠"我觉得没改"
ZW=0
while IFS= read -r L; do
    [ -n "$L" ] || continue
    K=$(echo "$L" | cut -d' ' -f1-3)
    NEWL=$(R FA.txt | grep -F "$K ")
    [ -n "$NEWL" ] || { echo "  AF_WEAKEN key=[$K] 活策略里没有这个 key 的任何写法"; ZW=$((ZW+1)); continue; }
    MISS=$(comm -23 <(echo "$L" | cut -d' ' -f4 | tr ',' '\n' | sort) \
                    <(echo "$NEWL" | cut -d' ' -f4 | tr ',' '\n' | sort) | tr -d '\n ')
    [ -n "$MISS" ] && { echo "  AF_WEAKEN key=[$K] 丢了权限=$MISS"; ZW=$((ZW+1)); }
done < <(comm -23 <(R TV.txt) <(R FA.txt))
echo "AF_ZW=$ZW (必须＝0)"

A1=$(comm -13 <(R FN.txt) <(R FA.txt) | grep -ac .); A2=$(comm -23 <(R FN.txt) <(R FA.txt) | grep -ac .)
M1=$(comm -23 <(T TN.txt) <(T TA.txt) | grep -ac .); M2=$(comm -13 <(T TN.txt) <(T TA.txt) | grep -ac .)
M3=$(comm -23 <(T TV.txt) <(T TA.txt) | grep -ac .)
AFV=ok
[ "$A1" = 0 ] && [ "$A2" = 0 ] || AFV=fail
[ "$M1" = 0 ] && [ "$M2" = 0 ] || AFV=fail
[ "$M3" = 0 ] || AFV=fail
[ "$ZW" = 0 ] || AFV=fail
echo "AF_VERDICT=$AFV (条件＝avtab 与 new.pol 0/0、ATAR 与 new.pol 0/0、厂商 ATAR 一行不少、零削弱)"
