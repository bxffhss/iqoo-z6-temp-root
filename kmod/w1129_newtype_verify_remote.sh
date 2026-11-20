#!/bin/bash
# w1129_newtype_verify_remote.sh —— 第 95 发(#234)的**离线**闸：在构建机上把"带新类型的整份图"造出来并量干净，
#   链只在这支全绿时才允许把 pol.new 推到设备上、才允许写 /sys/fs/selinux/load。
#   与 w1121(离线功能自测)的分工：w1121 证的是"**工具**会正确插类型"（含七把负对照）；
#   这一支证的是"**这一份要上机的图**"：输入＝设备上刚导出的厂商件(不是测试副本)，规则＝rules_newtype95.txt 原文。
# ★三把"新类型专属"的尺（少一把就等于没答 #234 的那格）：
#   ① TYPES 必须**恰好多 type 行的条数**（条数从 RULES 里现数，不是我印象里的数）；
#   ② ★**TMAP_DRIFT**＝前 3645 行逐行必须与厂商件相同——这条防的是"符号序≠值序 ⇒ 整表平移"那种
#      avtab 三元组差分**看不见**的坏(11-03 立的那把 positional 尺；只比字节数/md5 抓不住它)；
#   ③ **零残留**＝那把没配任何规则的第二类型(z6_unused_file)在 avtab 里必须 0 个节点，
#      而配了规则的 z6_probe_file 节点数必须＝RULES 里引用它的 allow 行数(现数)。
# 用法（远端，工作目录＝/home/lucy）：bash w1129_newtype_verify_remote.sh <源码.c> <源码md5> <pol 名> <rules 名>
#   ★源码与 md5 由链现场推／现场算，本件**自己编一份新二进制**(w1129_host，不覆盖 host/v3/v4/v5)：
#     拿 11-02 那份 `w1104_host` 去验 11-03 才写完的 tmap/delta ＝ 用陈件当新尺(11-03 现查发现它停在 10:35)。
# 输出键(全部现量，链按行取；判读由链做，本件不替链下结论)：
#   SRC_MD5_LOCAL= SRC_MD5_REMOTE= BUILD= BIN_MD5=
#   ORIG_MD5= ORIG_BYTES= ORIG_TYPES= ORIG_NODES= ORIG_POLICYVERS=
#   RT_ADDED= RT_REMOVED=
#   TMAP_ORIG_ROWS= TMAP_ORIG_TOTAL=
#   RULE_TYPE_LINES= RULE_ALLOW_PROBE_LINES=
#   INSERTED= MERGED= RULES_IN_FILE= NEW_MD5= NEW_BYTES= NEW_TYPES= NEW_NODES=
#   TMAP_NEW_ROWS= TMAP_NEW_TOTAL= TMAP_DRIFT= TMAP_PROBE_ROW= TMAP_UNUSED_ROW=
#   UNUSED_NODES= PROBE_NODE_LINE= C_ADDED= C_REMOVED= ZERO_WEAKEN=
#   RT2_ADDED= RT2_REMOVED= TMAP_RT2_SAME_ROWS= HEAD16_ORIG= HEAD16_NEW= VERDICT=
set -u
cd /home/lucy || exit 9
SRC=${1:-w1129_src.c}
SRCMD5=${2:-}
POL=${3:-pol.orig}
RULES=${4:-rules95.txt}
BIN=/home/lucy/w1129_host
LIB=/home/lucy/sepolsrc_host/src/libsepol.a
R() { grep -v '^DUMP_' "$1" | sort; }          # dump 的头部那些 DUMP_* 行不进差分
for f in "$SRC" "$POL" "$RULES"; do
    [ -f "$f" ] || { echo "[x] 缺 $f"; echo VERDICT=fail; exit 8; }
done
[ -f "$LIB" ] || { echo "[x] 缺 $LIB"; echo VERDICT=fail; exit 8; }
echo "SRC_MD5_LOCAL=$SRCMD5 SRC_MD5_REMOTE=$(md5sum "$SRC" | cut -d' ' -f1)"
[ -n "$SRCMD5" ] && [ "$SRCMD5" = "$(md5sum "$SRC" | cut -d' ' -f1)" ] || { echo "[x] 源码两端不一致 ⇒ 不验"; echo VERDICT=fail; exit 8; }
rm -f "$BIN"
gcc -O2 -Wall -I/home/lucy/sepolsrc/libsepol-3.4/include -I/home/lucy/sepolsrc/libsepol-3.4 \
    -o "$BIN" "$SRC" "$LIB" 2>n95_build.err || { echo "BUILD=失败"; tail -8 n95_build.err | sed 's/^/  /'; echo VERDICT=fail; exit 7; }
echo "BUILD=ok WARN=$(grep -ac 'warning:' n95_build.err) BIN_MD5=$(md5sum "$BIN" | cut -d' ' -f1)"
grep -a 'warning:' n95_build.err | head -3 | sed 's/^/  W /'
file "$BIN" | grep -q 'x86-64' || { echo "[x] BIN 不是 x86-64"; echo VERDICT=fail; exit 7; }

echo "ORIG_MD5=$(md5sum "$POL" | cut -d' ' -f1) ORIG_BYTES=$(wc -c < "$POL")"
"$BIN" dump "$POL" A.txt >/dev/null 2>&1 || { echo "[x] dump(厂商件) 失败"; echo VERDICT=fail; exit 7; }
echo "ORIG_TYPES=$(sed -n 's/^DUMP_TYPES=\([0-9]*\).*/\1/p' A.txt | head -1) ORIG_NODES=$(sed -n 's/^DUMP_NODES=\([0-9]*\).*/\1/p' A.txt | head -1) ORIG_POLICYVERS=$(sed -n 's/^DUMP_POLICYVERS=\([0-9]*\).*/\1/p' A.txt | head -1)"
echo "HEAD16_ORIG=$(od -An -tx1 -N16 "$POL" | tr -s ' ')"

# --- ① 空 delta 往返(语义尺)：同一份图过一遍读/写，三元组必须 0 差 ---
"$BIN" rt "$POL" rt.pol >/dev/null 2>&1 || { echo "[x] rt(厂商件) 失败"; echo VERDICT=fail; exit 7; }
"$BIN" dump rt.pol B.txt >/dev/null 2>&1
echo "RT_ADDED=$(comm -13 <(R A.txt) <(R B.txt) | grep -ac .) RT_REMOVED=$(comm -23 <(R A.txt) <(R B.txt) | grep -ac .)"

# --- ② ATAR 尺(厂商件那一侧) ---
"$BIN" tmap "$POL" tmap_orig.txt >/dev/null 2>&1 || { echo "[x] tmap(厂商件) 失败"; echo VERDICT=fail; exit 7; }
echo "TMAP_ORIG_ROWS=$(grep -ac '^TMAP ' tmap_orig.txt) TMAP_ORIG_TOTAL=$(sed -n 's/^TMAP_TOTAL=\([0-9]*\).*/\1/p' tmap_orig.txt)"

# --- 规则文件里的条数**现数**(闸的期望值必须来自被测输入，不来自我的印象；例 221) ---
NT=$(sed 's/#.*//' "$RULES" | grep -cE '^[[:space:]]*type[[:space:]]')
NP=$(sed 's/#.*//' "$RULES" | grep -cE '^[[:space:]]*allow.*z6_probe_file')
echo "RULE_TYPE_LINES=$NT RULE_ALLOW_PROBE_LINES=$NP"

# --- ③ 造 new ---
"$BIN" delta "$POL" new.pol "$RULES" >delta95.log 2>&1 || { echo "[x] delta 失败:"; grep -a '^ERROR' delta95.log | head -3; echo VERDICT=fail; exit 8; }
grep -a '^TYPE_INSERTED' delta95.log | sed 's/^/  /'
grep -a '^DECL_PARSED' delta95.log | sed 's/^/  /'
echo "INSERTED=$(sed -n 's/^.*INSERTED=\([0-9]*\).*/\1/p' delta95.log | head -1) MERGED=$(sed -n 's/^.*MERGED=\([0-9]*\).*/\1/p' delta95.log | head -1) RULES_IN_FILE=$(sed -n 's/^.*RULES_IN_FILE=\([0-9]*\).*/\1/p' delta95.log | head -1) WILD_RULES=$(sed -n 's/^.*WILD_RULES=\([0-9]*\).*/\1/p' delta95.log | head -1)"
"$BIN" dump new.pol C.txt >/dev/null 2>&1 || { echo "[x] dump(new) 失败"; echo VERDICT=fail; exit 7; }
NWT=$(sed -n 's/^DUMP_TYPES=\([0-9]*\).*/\1/p' C.txt | head -1)
NWN=$(sed -n 's/^DUMP_NODES=\([0-9]*\).*/\1/p' C.txt | head -1)
echo "NEW_MD5=$(md5sum new.pol | cut -d' ' -f1) NEW_BYTES=$(wc -c < new.pol) NEW_TYPES=$NWT NEW_NODES=$NWN"
echo "HEAD16_NEW=$(od -An -tx1 -N16 new.pol | tr -s ' ')"

# --- ④ ATAR 尺(new 那一侧)＋★漂移那一格 ---
"$BIN" tmap new.pol tmap_new.txt >/dev/null 2>&1 || { echo "[x] tmap(new) 失败"; echo VERDICT=fail; exit 7; }
TNR=$(grep -ac '^TMAP ' tmap_new.txt)
echo "RULES_MD5=$(md5sum "$RULES" | cut -d' ' -f1)"
echo "TMAP_NEW_ROWS=$TNR TMAP_NEW_TOTAL=$(sed -n 's/^TMAP_TOTAL=\([0-9]*\).*/\1/p' tmap_new.txt)"
DRIFT=$(comm -23 <(grep -a '^TMAP ' tmap_orig.txt) <(grep -a '^TMAP ' tmap_new.txt) | grep -ac .)
echo "TMAP_DRIFT=$DRIFT (前 3645 行里**少了/变了**的厂商行条数；必须＝0)"
grep -a ' z6_probe_file ' tmap_new.txt | head -1 | sed 's/^/TMAP_PROBE_ROW=/'
grep -a ' z6_unused_file ' tmap_new.txt | head -1 | sed 's/^/TMAP_UNUSED_ROW=/'

# --- ⑤ avtab 差分＋零削弱(机械证明，不靠"我觉得没改") ---
echo "C_ADDED=$(comm -13 <(R A.txt) <(R C.txt) | grep -ac .) C_REMOVED=$(comm -23 <(R A.txt) <(R C.txt) | grep -ac .)"
comm -13 <(R A.txt) <(R C.txt) | sed 's/^/  ADD /'
ZW=0
while IFS= read -r L; do
    [ -n "$L" ] || continue
    K=$(echo "$L" | cut -d' ' -f1-3)
    NEWL=$(R C.txt | grep -F "$K ")
    [ -n "$NEWL" ] || { echo "  WEAKEN key=[$K] 新写法根本没回来"; ZW=$((ZW+1)); continue; }
    MISS=$(comm -23 <(echo "$L" | cut -d' ' -f4 | tr ',' '\n' | sort) \
                    <(echo "$NEWL" | cut -d' ' -f4 | tr ',' '\n' | sort) | tr -d '\n ')
    [ -n "$MISS" ] && { echo "  WEAKEN key=[$K] 丢了权限=$MISS"; ZW=$((ZW+1)); }
done < <(comm -23 <(R A.txt) <(R C.txt))
echo "ZERO_WEAKEN=$ZW (必须＝0)"

# --- ⑥ 两把新类型各自的"节点代价" ---
UN=$(grep -ac 'z6_unused_file' C.txt)
PR=$(grep -ac 'z6_probe_file' C.txt)
echo "UNUSED_NODES=$UN (这把没配任何规则 ⇒ 必须＝0) PROBE_NODES=$PR (必须＝RULE_ALLOW_PROBE_LINES 里的 allow 行数)"
grep -a 'z6_probe_file' C.txt | sed 's/^/PROBE_NODE_LINE=/'

# --- ⑦ 要上机的那一份过一遍**自己的读写器**：稳定性(上机前最后一把结构尺) ---
"$BIN" rt new.pol rt2.pol >/dev/null 2>&1 || { echo "[x] rt(new) 失败"; echo VERDICT=fail; exit 7; }
"$BIN" dump rt2.pol E.txt >/dev/null 2>&1
"$BIN" tmap new.pol tmap_new2.txt >/dev/null 2>&1
echo "RT2_ADDED=$(comm -13 <(R C.txt) <(R E.txt) | grep -ac .) RT2_REMOVED=$(comm -23 <(R C.txt) <(R E.txt) | grep -ac .)"
echo "TMAP_RT2_SAME_ROWS=$(comm -12 <(grep -a '^TMAP ' tmap_new.txt) <(grep -a '^TMAP ' tmap_new2.txt) | grep -ac .)/$(grep -ac '^TMAP ' tmap_new.txt)"

# --- 定调(全是"输入决定"的不变式：条数来自 RULES 现数，量值本身交给链) ---
OT=$(sed -n 's/^DUMP_TYPES=\([0-9]*\).*/\1/p' A.txt | head -1)
RTA=$(comm -13 <(R A.txt) <(R B.txt) | grep -ac .); RTB=$(comm -23 <(R A.txt) <(R B.txt) | grep -ac .)
RT2A=$(comm -13 <(R C.txt) <(R E.txt) | grep -ac .); RT2B=$(comm -23 <(R C.txt) <(R E.txt) | grep -ac .)
V=ok
[ "$RTA" = 0 ] && [ "$RTB" = 0 ] || V=fail          # 往返语义尺：厂商件过一遍读写必须 0 差
[ "$RT2A" = 0 ] && [ "$RT2B" = 0 ] || V=fail        # 要上机那一份自己也必须 0 差
[ "$DRIFT" = 0 ] || V=fail                          # 前 3645 行 ATAR 不许有一行动过
[ "$ZW" = 0 ] || V=fail                              # 零削弱
[ "$UN" = 0 ] || V=fail                              # 没配规则的新类型不得带来节点
[ "$PR" = "$NP" ] || V=fail                          # 配了规则的新类型节点数＝引用它的行数
[ "$NWT" = "$((OT + NT))" ] || V=fail                  # 类型表恰好长 NT 行
[ "$TNR" = "$NWT" ] || V=fail                          # tmap 尺与 dump 尺必须互相咬合
echo "VERDICT=$V (条件＝往返0差/新件往返0差/ATAR漂移0/零削弱/未用类型0节点/探针节点=$NP/类型表 $OT->$NWT)"
