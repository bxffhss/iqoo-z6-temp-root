#!/bin/bash
# w1126_community_cost.sh —— 量"两家社区模块的**真实** sepolicy.rule 能不能原样落地"（**0 枪**，只在构建机上跑）。
#   为什么值得单独一发：#232/#233 之后我手里的能力是用**自造样例**验的；目标③ 说的是"别人的模块"，
#     所以判据必须换成第三方原文，而且要**逐行**——一份文件里只要有一行落不了，整包就落不了；
#     只报"整包失败"等于没答(会把"这台机没有这个类型"和"我的工具不会展开"混成一谈)。
#   判读(写死)：
#     WHOLE_*=ok ＋ PERLINE_* 落不下=0 ⇒ "这份原文能原样进活策略"(仍只是**离线**，内核收不收＝#234)；
#     WHOLE_*=rejected 且 UNRESOLVED_* 非空 ⇒ 墙在**厂商类型表**(AOSP 有、这台机没有)＝目标③ 的真实成本，
#       要跨过它只能"凭空造一个厂商没有的类型"——那规则会是**死条款**(没有进程/文件带这个标签)，不许当能力宣称；
#     代价一律按 WHOLE_* 里的 `nodes=`/`bytes=` 记账，不事后追述。
#   ★不碰设备、不开窗、不写 /sys/fs/selinux/load。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
RM_CLI=hermes-remote1/cli.py; RM_CFG=hermes-remote1/config.json
REXEC() { HRMT_CLI=$RM_CLI W682_T=480 PYTHONUTF8=1 python kmod/w682_rr.py "$1" 2>&1 | tr -d '\r'; }
RPUSH() { HRMT_CLI=$RM_CLI python $RM_CLI --config $RM_CFG put "$1" "$2" 2>&1 | tail -1; }
if [ -n "${MSYS_NO_PATHCONV+set}" ]; then echo "[x] MSYS_NO_PATHCONV 被定义了(哪怕空值) ⇒ 拒跑(见例 218)"; exit 3; fi

CSRC=kmod/w1104_delta.c; RSRC=kmod/w1125_community_cost_remote.sh
POLFILE=$EV/w1117_pol.orig_94
LSP=kmod/_tmp_modules/LSPosed-v2.2.0-7854-release/sepolicy.rule
ZYG=kmod/_tmp_modules/Zygisk-Next-1.5.2-864-a4a72ce-relea/sepolicy.rule
VENDOR=282a68611a2f36321a153fc0102f9ca0; VBYTES=1356948

echo "[1/3] 离线总闸(现跑)＋陈旧源码闸"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 先补前置"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

echo "[2/3] 五件本机的现值(不背历史)"
SM=$(md5sum $CSRC | cut -d' ' -f1); PM=$(md5sum $POLFILE | cut -d' ' -f1); PB=$(wc -c < $POLFILE)
echo "  w1104_delta.c md5=$SM 行数=$(wc -l < $CSRC)／远端半支 md5=$(md5sum $RSRC | cut -d' ' -f1)"
echo "  pol.orig=$PB B md5=$PM (应＝$VENDOR/$VBYTES)"
[ "$PM" = "$VENDOR" ] && [ "$PB" = "$VBYTES" ] || { echo "[x] 底件不是厂商那份 ⇒ 换凭据，不跑"; exit 1; }
for f in "$LSP" "$ZYG"; do
    [ -f "$f" ] || { echo "[x] 第三方原文不在：$f ⇒ 这一格没法跑(不许拿我抄的副本当真源)"; exit 1; }
    echo "  $(wc -l < "$f") 行 md5=$(md5sum "$f" | cut -d' ' -f1)  ← $f"
done

echo "[3/3] 推五件＋远端跑两把(整包／逐行)"
RPUSH "$CSRC" w1125_src_put.c | sed 's/^/  put src: /'
RPUSH "$RSRC" w1125_cost.sh   | sed 's/^/  put leg: /'
RPUSH "$POLFILE" pol.cst       | sed 's/^/  put pol: /'
RPUSH "$LSP" rules_lsposed.txt | sed 's/^/  put lsp: /'
RPUSH "$ZYG" rules_zygisk.txt  | sed 's/^/  put zyg: /'
OUT=$(REXEC "cd /home/lucy; bash w1125_cost.sh w1125_src_put.c $SM pol.cst rules_lsposed.txt rules_zygisk.txt")
echo "$OUT" | grep -aE '^(SRC_MD5_LOCAL|POL_MD5|BUILD=|RULES_MD5|RULES_LINES|WHOLE_lsposed|WHOLE_zygisk|PERLINE_|UNRESOLVED_|LINE[0-9]+=|COST_VERDICT)|^  (WHOLE|TYPE_INSERTED|ATTR_ADDED|PERM_STAR|WILD_)' | sed 's/^/    /' | cut -c1-210
echo "$OUT" > $EV/w1126_community_cost.txt
echo "  全文存 $EV/w1126_community_cost.txt($(wc -c < $EV/w1126_community_cost.txt) B)"
echo "  ★读法提醒：WHOLE_*=ok 只说明**离线**能构造出这份图；内核收不收＝未测(#234，装载要单独点头)。UNRESOLVED_* 非空＝墙在厂商类型表，不在我的工具。"
