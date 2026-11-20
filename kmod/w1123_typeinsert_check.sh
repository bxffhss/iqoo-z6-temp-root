#!/bin/bash
# w1123_typeinsert_check.sh —— #232「插新类型」那一格的离线判定链（**0 枪**，只在构建机上跑，不碰设备）。
#   形状：本机跑离线总闸 → 现算源码 md5 → 推(源码／远端半支／厂商 pol.orig／第 93 发那份 rules.txt) →
#     远端编 x86 新件 w1104_v4(不覆盖 v3/host) → 四把负对照 + 正例(插 1 型 2 规则) + 老路径 md5 回归 + 往返稳定。
#   ★为什么要有"丙(老路径 md5 回归)"这一把：我把 parse_rules 改成了两遍扫描，"新加的能跑"不等于"原来那条没被改坏"；
#     拿第 93 发已装载成功那份的 md5 当尺，是唯一能机械回答"字节级还是同一件"的证人(语义尺另见 w1119)。
#   判读：TI_VERDICT=ok 且 NEG_ZEROS=0 且 shell93_md5_same=1 且 rows_added=1 且 shared_diff=0 且 avtab=+2/-0 且 rt_diff=0。
#     任何一把缺 ⇒ 记未测，不许往下推"社区模块的类型能落地"。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
RM_CLI=hermes-remote1/cli.py; RM_CFG=hermes-remote1/config.json
REXEC() { HRMT_CLI=$RM_CLI W682_T=260 PYTHONUTF8=1 python kmod/w682_rr.py "$1" 2>&1 | tr -d '\r'; }
RPUSH() { HRMT_CLI=$RM_CLI python $RM_CLI --config $RM_CFG put "$1" "$2" 2>&1 | tail -1; }
if [ -n "${MSYS_NO_PATHCONV+set}" ]; then echo "[x] MSYS_NO_PATHCONV 被定义了(哪怕空值) ⇒ 拒跑(见例 218)"; exit 3; fi

CSRC=kmod/w1104_delta.c; RSRC=kmod/w1121_typeinsert_verify_remote.sh
POLFILE=$EV/w1117_pol.orig_94; RULES=kmod/sepolicy_delta/rules.txt
VENDOR=282a68611a2f36321a153fc0102f9ca0; VBYTES=1356948
WANTNEW=1b60730d632f6c8be24da342c1c7c0b7      # 第 93 发那份 pol.new(已在设备上装过、内核收下的那件)

echo "[1/3] 离线总闸(现跑)＋陈旧源码闸"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 先补前置"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

echo "[2/3] 四件本机的现值(不背历史)"
SM=$(md5sum $CSRC | cut -d' ' -f1); RM=$(md5sum $RSRC | cut -d' ' -f1)
PM=$(md5sum $POLFILE | cut -d' ' -f1); PB=$(wc -c < $POLFILE)
RLM=$(md5sum $RULES | cut -d' ' -f1)
echo "  源码 md5=$SM ($(wc -l < $CSRC) 行)／远端半支 md5=$RM"
echo "  pol.orig=$PB B md5=$PM (应＝$VENDOR/$VBYTES)／rules.txt md5=$RLM(第93发那份) 期望产物 md5=$WANTNEW"
[ "$PM" = "$VENDOR" ] && [ "$PB" = "$VBYTES" ] || { echo "[x] 底件不是厂商那份 ⇒ 换凭据，不跑"; exit 1; }
[ "$RLM" = "4ffcd969a19e3b3e6cfcc64dcd1a8ea2" ] || echo "  [!] rules.txt 与第 93 发登记值不同($RLM) ⇒ 丙那把回归尺的期望值要跟着改，先看差异再跑"

echo "[3/3] 推四件＋远端判定"
RPUSH "$CSRC"    w1121_src_put.c   | sed 's/^/  put src: /'
RPUSH "$RSRC"    w1121_verify.sh   | sed 's/^/  put leg: /'
RPUSH "$POLFILE" pol.ti            | sed 's/^/  put pol: /'
RPUSH "$RULES"   rules93.ti        | sed 's/^/  put rl : /'
OUT=$(REXEC "cd /home/lucy; bash w1121_verify.sh w1121_src_put.c $SM pol.ti rules93.ti $WANTNEW")
echo "$OUT" | grep -aE '^(SRC_MD5_LOCAL|POL_MD5|RULES_MD5|BUILD|SHELL93_rc|NEG[0-9]_rc|NEG_ZEROS|POS_rc|TI_ROWS|TI_SHARED_DIFF|TI_SUMMARY|TI_RT_DIFF|TI_BYTES|NODES|WNE[0-9]_rc|WNE_ZEROS|WPOS_rc|WILD_SUMMARY|ERROR)|^  (W|D|ADD|NEWROW|TABLE|DECL_PARSED|TYPE_INSERTED|ATTR_ADDED|TYPE_SECOND_NAME|RULES_PARSED|INSERTED|MERGED|PERM_STAR|WILD_)' | sed 's/^/    /'
echo "$OUT" > $EV/w1123_typeinsert.txt
echo "  全文存 $EV/w1123_typeinsert.txt"
V=$(echo "$OUT" | sed -n 's/^TI_VERDICT=//p'); S=$(echo "$OUT" | sed -n '/^TI_SUMMARY/,$p' | head -1)
echo "  判读：TI_VERDICT=[$V] 汇总行=[$S]"
[ "$V" = ok ] || { echo "[x] 没过 ⇒ 上面抄出的行里哪一把红就补哪一把；不许据此说\"插新类型/通配可行\""; exit 1; }
echo "★判正：插新类型＋通配展开这两格在**离线**上尺齐(形状/语义/老路径回归/往返稳定/展开数与独立 dump 对账)，七把负对照都有牙 ⇒ 下一格才是设备上那一枪(装载要单独点头)"
