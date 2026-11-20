#!/bin/bash
# w1125_community_cost_remote.sh —— 拿**两家社区模块的真实 `sepolicy.rule` 原文**量一遍(#233/#232 之后的"还欠什么")。0 枪，只在构建机上跑。
#   为什么要这一格：93/94 之后我手里是"能插类型＋能展开通配"，但那还是**我自己造的样例**。目标③ 要的是"社区写的那份能不能原样落地"，
#   所以判据必须换成**第三方原文**，而且要逐行——一份文件里只要有一行落不了，整包就落不了；只报"整包失败"没用人话。
#   产出(一行一键)：
#     甲 WHOLE_<tag>=ok|rej:<第一条理由> ＋ WHOLE_<tag>_jobs/inserted/nodes/bytes —— 整份原文一次跑的样子(含节点与字节**代价**)；
#     乙 逐行 LINE<n>=ok|rej:<理由> ＋ LANDABLE=/UNLANDABLE= —— **带着"把所有新类型先声明好"这个前提**逐行数；
#     丙 UNRESOLVED=... —— 这台机活策略里**根本不存在**的那些名字(AOSP 有、vendor 没有)＝这一格真正的墙；
#     丁 COST_VERDICT=ok|partial|blocked。
#   ★不碰设备、不开窗、不写 /sys/fs/selinux/load；不覆盖任何在用件(自己编到 w1104_v5)。
set -u
cd /home/lucy || exit 9
SRCPUT=${1:?源码名}; SRCMD5=${2:?源码md5}; POL=${3:?pol名}
LSP=${4:?lsposed rules名}; ZYG=${5:?zygisk rules名}
SRC=/home/lucy/w1125_src.c; BIN=/home/lucy/w1104_v5
LIB=/home/lucy/sepolsrc_host/src/libsepol.a

cp "$SRCPUT" "$SRC" 2>/dev/null || { echo "SRC_CP=失败"; echo "COST_VERDICT=fail"; exit 7; }
RM5=$(md5sum "$SRC" | cut -d' ' -f1)
echo "SRC_MD5_LOCAL=$SRCMD5 SRC_MD5_REMOTE=$RM5"
[ "$RM5" = "$SRCMD5" ] || { echo "[x] 远端源码不是本机那份"; echo "COST_VERDICT=fail"; exit 7; }
rm -f "$BIN"
gcc -O2 -Wall -I/home/lucy/sepolsrc/libsepol-3.4/include -I/home/lucy/sepolsrc/libsepol-3.4 \
    -o "$BIN" "$SRC" "$LIB" 2>cst_build.err || { echo "BUILD=失败"; tail -8 cst_build.err | sed 's/^/  /'; echo "COST_VERDICT=fail"; exit 7; }
echo "BUILD=ok WARN=$(grep -ac 'warning:' cst_build.err)"
file "$BIN" | grep -q 'x86-64' || { echo "[x] BIN 不是 x86-64"; echo "COST_VERDICT=fail"; exit 7; }
echo "POL_MD5=$(md5sum "$POL" | cut -d' ' -f1) POL_BYTES=$(wc -c < "$POL")"
for t in lsposed zygisk; do
    f=$( [ "$t" = lsposed ] && echo "$LSP" || echo "$ZYG" )
    echo "----- 第三方原文 $t -----"
    md5sum "$f" | cut -c1-32 | sed 's/^/RULES_MD5_/'
    grep -acv '^\s*$' "$f" | sed 's/^/RULES_LINES_/'
    # --- 甲：整份一次跑 ---
    rm -f cst.pol
    "$BIN" delta "$POL" cst.pol "$f" > cst_$t.log 2>&1; R=$?
    if [ "$R" = 0 ]; then
        "$BIN" dump "$POL" cstA.txt >/dev/null 2>&1; "$BIN" dump cst.pol cstB.txt >/dev/null 2>&1
        echo "WHOLE_$t=ok jobs=$(sed -n 's/^JOBS=\([0-9]*\).*/\1/p' cst_$t.log|head -1) inserted=$(sed -n 's/^INSERTED=\([0-9]*\).*/\1/p' cst_$t.log|head -1) nodes=$(sed -n 's/^DUMP_NODES=\([0-9]*\).*/\1/p' cstA.txt)->$(sed -n 's/^DUMP_NODES=\([0-9]*\).*/\1/p' cstB.txt) bytes=$(wc -c < "$POL")->$(wc -c < cst.pol)"
        grep -aE '^(TYPE_INSERTED|ATTR_ADDED|PERM_STAR|WILD_UNIVERSE|WILD_PLAN)' cst_$t.log | sed 's/^/  /'
        rm -f cst.pol
    else
        echo "WHOLE_$t=rejected rc=$R 第一条理由=[$(grep -a '^ERROR' cst_$t.log | head -1 | cut -c1-150)]"
    fi
    # --- 乙：逐行(前提＝把这份文件里所有 type/typeattribute 声明先做好) ---
    DECL=$(grep -aE '^[[:space:]]*(type|typeattribute)[[:space:]]' "$f")
    n=0; OK=0; NO=0; : > cst_unres.txt
    while IFS= read -r LINE; do
        case "$LINE" in ''|\#*) continue ;; esac
        FIRST=$(awk '{print $1; exit}' <<<"$LINE")
        case "$FIRST" in type|typeattribute) continue ;; esac
        n=$((n + 1))
        printf '%s\n%s\n' "$DECL" "$LINE" > cst_line.txt
        rm -f cst_line.pol
        "$BIN" delta "$POL" cst_line.pol cst_line.txt > cst_line.log 2>&1; LR=$?
        if [ "$LR" = 0 ]; then
            OK=$((OK + 1)); echo "LINE$n=ok [$(cut -c1-58 <<<"$LINE")] jobs=$(sed -n 's/^JOBS=\([0-9]*\).*/\1/p' cst_line.log|head -1)"
        else
            NO=$((NO + 1))
            RS=$(grep -a '^ERROR' cst_line.log | head -1 | cut -c1-120)
            echo "LINE$n=rejected [$(cut -c1-58 <<<"$LINE")] 理由=[$RS]"
            grep -ao "unresolvable type name '[a-zA-Z0-9_.-]*'" cst_line.log | sed "s/.*'\(.*\)'/\1/" >> cst_unres.txt
            grep -ao "attribute '[a-zA-Z0-9_.-]*' 不在这份策略里" cst_line.log | sed "s/attribute '\(.*\)'.*/\1/" >> cst_unres.txt
        fi
        rm -f cst_line.pol cst_line.txt
    done < "$f"
    echo "PERLINE_$t: allow行=$n 落得下=$OK 落不下=$NO"
    sort -u cst_unres.txt | tr '\n' ' ' | sed "s/^/UNRESOLVED_$t=/"
    echo "  (上面这份清单＝这台机活策略里【不存在】的名字；AOSP 有、vendor 没有 ⇒ 这才是目标③ 的墙，不是「我不会展开」)"
done
# --- 丁：定调(判读交给链按行取，本件不替链下结论) ---
echo "COST_VERDICT=done (整包两把看 WHOLE_lsposed/WHOLE_zygisk，逐行两把看 PERLINE_*；代价＝WHOLE_* 里的 nodes/bytes)"
