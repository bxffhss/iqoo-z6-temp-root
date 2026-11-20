#!/bin/bash
# w1121_typeinsert_verify_remote.sh —— #232/#233「往类型表尾部插新类型」＋「通配展开」的离线判定件（0 枪，只在构建机上跑）。
#   它要答的问题只有一个：**我插进去/展开出来的那一格，内核读的时候会不会跟它对不上？**
#   五把尺互相顶替不了，所以分开量：
#     甲(形状) 新行 = `TMAP 3646 <名字> self=1 ATTR=<属性>`，且**头 3645 行与插之前逐行相同**
#              ⇒ 那张"按位置"的属性映射没有因为尾部加一格而漂移（漂移=全表错位，93/94 的三元组判据看不见它）；
#     乙(语义) avtab 三元组差分 = 恰 +N / −0 ⇒ 除我要开的门以外没放开任何东西；
#     丙(回归) 拿第 93 发那份 rules.txt 重跑，产物的 md5 必须**仍等于** 1b60730d… ⇒ 我加的两遍扫描没改坏老路径；
#     丁(稳定) 插完的这份再读一遍再写一遍，那张表还逐行相同 ⇒ 内核见到的是文件，不是我的内存；
#     戊(对账) 通配那条规则：`WILD_UNIVERSE` 的具体类型数、`JOBS` 的计划项数、`INSERTED+MERGED`、`VERIFIED`，
#              再加**独立跑一遍 dump** 数出来的三元组增量——五个数必须互相吻合。只印一个"INSERTED=3267"不算证，
#              那可能只是我自己算给自己看。
#   再加七把**负对照**（判据必须有牙）：属性不存在／给不存在的类型补票／规则引用没声明的名字／声明一个已有名字／
#   `allow * * ...`(两侧通配＝具体类型数的平方)／`{ read * }`(`*` 与具名权限混写)／19 条通配规则撞 MAXJOBS——
#   七把都必须非零退出**且没留下产物**。任何一把静默通过，就是"把没做的读成做完了"。
#   用法：w1121_typeinsert_verify_remote.sh <已put的源码名> <源码md5> <已put的pol.orig名> <已put的rules.txt名> <期望pol.new的md5>
set -u
cd /home/lucy || exit 9
SRCPUT=${1:?源码名}; SRCMD5=${2:?源码md5}; POL=${3:?pol名}; RULES=${4:?rules名}; WANTNEW=${5:?期望md5}
SRC=/home/lucy/w1121_src.c
BIN=/home/lucy/w1104_v4                       # ★新件，别覆盖 w1104_host / w1104_v3
LIB=/home/lucy/sepolsrc_host/src/libsepol.a

cp "$SRCPUT" "$SRC" 2>/dev/null || { echo "SRC_CP=失败"; echo "TI_VERDICT=fail"; exit 7; }
RM5=$(md5sum "$SRC" | cut -d' ' -f1)
echo "SRC_MD5_LOCAL=$SRCMD5 SRC_MD5_REMOTE=$RM5"
[ "$RM5" = "$SRCMD5" ] || { echo "[x] 远端源码不是本机那份 ⇒ 编出来的件不算数"; echo "TI_VERDICT=fail"; exit 7; }
md5sum "$RULES" | cut -c1-32 | sed 's/^/RULES_MD5=/'

rm -f "$BIN"
gcc -O2 -Wall -I/home/lucy/sepolsrc/libsepol-3.4/include -I/home/lucy/sepolsrc/libsepol-3.4 \
    -o "$BIN" "$SRC" "$LIB" 2>ti_build.err || { echo "BUILD=失败"; tail -8 ti_build.err | sed 's/^/  /'; echo "TI_VERDICT=fail"; exit 7; }
echo "BUILD=ok WARN=$(grep -ac 'warning:' ti_build.err)"
grep -a 'warning:' ti_build.err | head -3 | sed 's/^/  W /'
file "$BIN" | grep -q 'x86-64' || { echo "BIN 不是 x86-64"; echo "TI_VERDICT=fail"; exit 7; }

# --- 丙：老路径回归（第 93 发那份 3 条 shell 规则，产物 md5 必须还是老值）---
"$BIN" delta "$POL" ti_shell.pol "$RULES" >ti_shell.log 2>&1
echo "SHELL93_rc=$?  md5=$(md5sum ti_shell.pol 2>/dev/null | cut -d' ' -f1) 期望=$WANTNEW"
grep -aE '^RULES_PARSED|^INSERTED|^MERGED' ti_shell.log | sed 's/^/  /'

# --- 四把负对照：都必须非零退出，且报错文字要说清为什么 ---
printf 'type z6_neg_probe nsfs\n' > t_neg1.txt
printf 'typeattribute shell z6_no_such_attr\n' > t_neg2.txt
printf 'allow z6_undeclared_name shell:dir search\n' > t_neg3.txt
printf 'type shell file_type\nallow shell z6_neg_probe file read\n' > t_neg4.txt
NG=0
for n in 1 2 3 4; do
    rm -f "t_neg$n.pol"
    "$BIN" delta "$POL" "t_neg$n.pol" "t_neg$n.txt" >"t_neg$n.log" 2>&1
    R=$?
    # ★落点不许用 /dev/null：写进 /dev/null 时 ftell=0，工具会因"写不出字节"而红＝错的理由。
    #   所以落真文件：rc=0 或留下了产物，都算这把判据没牙（跑完即删，不留陈件）。
    HAS=无
    [ -s "t_neg$n.pol" ] && HAS=是-不该有
    # ★rc 与"被拒的理由"必须并排印(例 220 那一课)：stdout 是块缓冲、stderr 不缓冲，"末行"往往是 stdout 的最后一句，
    #   不是 ERROR 那行 ⇒ 直接把日志里第一条 ^ERROR 抽出来当证人。
    ERR=$(grep -a '^ERROR' "t_neg$n.log" | head -1 | cut -c1-170)
    echo "NEG${n}_rc=$R 产物=$HAS 理由=[$ERR]"
    if [ "$R" = 0 ] || [ "$HAS" != 无 ]; then NG=$((NG+1)); echo "[x] 负$n 被收下了 ⇒ 判据没牙"; fi
    rm -f "t_neg$n.pol"
done
echo "NEG_ZEROS=$NG (期望=0)"

# --- 甲＋乙：正例（插一个新类型 + 两条引用它的规则）---
printf 'type z6_probe_file file_type\nallow z6_probe_file shell:dir search\nallow shell z6_probe_file file read\n' > t_pos.txt
"$BIN" tmap "$POL" t_before.txt > /dev/null 2>&1 || { echo "TMAP_BEFORE=跑不通"; echo "TI_VERDICT=fail"; exit 8; }
"$BIN" delta "$POL" t_pos.pol t_pos.txt > t_pos.log 2>&1
echo "POS_rc=$?"
grep -aE '^DECL_PARSED|^TYPE_INSERTED|^ATTR_ADDED|^TABLE |^RULES_PARSED|^INSERTED|^TYPE_SECOND_NAME' t_pos.log | sed 's/^/  /'
"$BIN" dump "$POL" t_A.txt >/dev/null 2>&1
"$BIN" dump t_pos.pol t_B.txt >/dev/null 2>&1
echo "NODES before=$(sed -n 's/^DUMP_NODES=\([0-9]*\).*/\1/p' t_A.txt) after=$(sed -n 's/^DUMP_NODES=\([0-9]*\).*/\1/p' t_B.txt)"
echo "TI_ADDED=$(comm -13 <(grep -v '^DUMP_' t_A.txt|sort) <(grep -v '^DUMP_' t_B.txt|sort)|grep -ac .) TI_REMOVED=$(comm -23 <(grep -v '^DUMP_' t_A.txt|sort) <(grep -v '^DUMP_' t_B.txt|sort)|grep -ac .)"
comm -13 <(grep -v '^DUMP_' t_A.txt|sort) <(grep -v '^DUMP_' t_B.txt|sort) | sed 's/^/  ADD /'
NB=$(grep -ac '^TMAP ' t_before.txt)
"$BIN" tmap t_pos.pol t_after.txt > /dev/null 2>&1 || { echo "TMAP_AFTER=跑不通"; echo "TI_VERDICT=fail"; exit 8; }
NA=$(grep -ac '^TMAP ' t_after.txt)
echo "TI_ROWS before=$NB after=$NA (期望恰 +1)"
echo "TI_SHARED_DIFF=$(diff <(head -"$NB" t_after.txt) <(grep -a '^TMAP ' t_before.txt) | grep -ac '^[<>]') (期望=0；只比这 $NB 行，尾计数行不进比较)"
tail -2 t_after.txt | sed 's/^/  NEWROW /'
# --- 丁：插完的这份**再读一遍再写一遍**，还稳不稳（内核见到的是文件，不是我的内存）---
"$BIN" rt t_pos.pol t_pos2.pol >/dev/null 2>&1
"$BIN" tmap t_pos2.pol t_after2.txt >/dev/null 2>&1
echo "TI_RT_DIFF=$(diff <(grep -a '^TMAP ' t_after.txt) <(grep -a '^TMAP ' t_after2.txt) | grep -ac '^[<>]') (期望=0)"
echo "TI_BYTES after=$(wc -c < t_pos.pol) after_rt=$(wc -c < t_pos2.pol) 原pol=$(wc -c < $POL)"

# --- 戊：通配主体 `*` 与权限 `*`(#233)：内核 ss 里 wildcard 零命中 ⇒ 只能在写侧展开，所以展开的**账**要自己会说话 ---
printf 'type z6_wild_probe file_type\nallow * z6_wild_probe file *\nallow z6_wild_probe shell dir read\n' > t_wpos.txt
printf 'allow * * file read\n' > t_wne1.txt                                   # 两侧都通配＝具体类型数的平方，必须拒
printf 'type z6_w2 file_type\nallow z6_w2 shell file { read * }\n' > t_wne2.txt # `*` 与具名权限混写，不猜子集
awk 'BEGIN{for(i=0;i<19;i++) print "allow * shell dir search"}' > t_wne3.txt   # 18×3265<60000<19×3265 ⇒ 必须撞 MAXJOBS
WG=0
for n in 1 2 3; do
    rm -f "t_wne$n.pol"
    "$BIN" delta "$POL" "t_wne$n.pol" "t_wne$n.txt" >"t_wne$n.log" 2>&1
    R=$?
    HAS=无
    [ -s "t_wne$n.pol" ] && HAS=是-不该有
    # ★整段用双引号包住：命令替换的结果若不加引号，其中的 `*` 会被 shell 拿去做路径展开(11-03 手动跑时被展开成
    #   整份目录清单，看着像工具疯了，其实是我的打印疯了)。理由文字必须**原样**进证件。
    echo "WNE${n}_rc=$R 产物=$HAS 理由=[$(grep -a '^ERROR' "t_wne$n.log" | head -1 | cut -c1-150)]"
    if [ "$R" = 0 ] || [ "$HAS" != 无 ]; then WG=$((WG + 1)); echo "[x] 通配负$n 被收下 ⇒ 判据没牙"; fi
    rm -f "t_wne$n.pol"
done
echo "WNE_ZEROS=$WG (期望=0)"
"$BIN" tmap "$POL" u_before.txt >/dev/null 2>&1
"$BIN" delta "$POL" t_wpos.pol t_wpos.txt > t_wpos.log 2>&1
WPOS_RC=$?
grep -aE '^(TYPE_INSERTED|PERM_STAR|WILD_UNIVERSE|WILD_PLAN|JOBS=|INSERTED=|ERROR)' t_wpos.log | sed 's/^/  /'
"$BIN" dump "$POL" U0.txt >/dev/null 2>&1
"$BIN" dump t_wpos.pol U1.txt >/dev/null 2>&1
"$BIN" tmap t_wpos.pol u_after.txt >/dev/null 2>&1
MU=$(grep -ac '^TMAP ' u_before.txt); NU=$(grep -ac '^TMAP ' u_after.txt)
WAD=$(comm -13 <(grep -v '^DUMP_' U0.txt|sort) <(grep -v '^DUMP_' U1.txt|sort) | grep -ac .)
WRM=$(comm -23 <(grep -v '^DUMP_' U0.txt|sort) <(grep -v '^DUMP_' U1.txt|sort) | grep -ac .)
WSH=$(diff <(head -"$MU" u_after.txt) <(grep -a '^TMAP ' u_before.txt) | grep -ac '^[<>]')
# ★展开条数自己核一遍：`allow * <新类型> file *` 应摊出"具体类型个数"那么多项(含刚插的那个)，再加那条具名规则。
# ★★取数教训(11-03 这一发就是被它抓住的)：`INSERTED/MERGED/VERIFIED` 是**同一行**打的，
#   用 `sed -n 's/^VERIFIED=…'` 只能从**行首**匹配 ⇒ 取到空串 ⇒ 判据 fail-closed 报"wild_ok=0"，
#   而读数本身是齐的。⇒ 一行里的多个字段必须先**把整行抓出来**，再在这一行里逐个 sed。
WLINE=$(grep -a '^INSERTED=' t_wpos.log | head -1)
UNIV=$(sed -n 's/^WILD_UNIVERSE primary_types=\([0-9]*\).*/\1/p' t_wpos.log | head -1)
JOBN=$(sed -n 's/^JOBS=\([0-9]*\).*/\1/p' t_wpos.log | head -1)
INSD=$(sed -n 's/^INSERTED=\([0-9]*\).*/\1/p' <<<"$WLINE")
MERGE_N=$(sed -n 's/.*MERGED=\([0-9]*\).*/\1/p' <<<"$WLINE")
VRFD=$(sed -n 's/.*VERIFIED=\([0-9]*\).*/\1/p' <<<"$WLINE")
echo "取的三个数(来自同一行现抓)：INSD=[$INSD] MERGE_N=[$MERGE_N] VRFD=[$VRFD] 原行=[$WLINE]"
WPOS_N=${WPOS_RC:-9}
echo "WPOS_rc=$WPOS_N bytes=$(wc -c < t_wpos.pol 2>/dev/null)"
echo "WILD_SUMMARY universe=$UNIV jobs=$JOBN inserted=$INSD merged=$MERGE_N verified=$VRFD avtab=+$WAD/-$WRM rows=$((NU-MU)) shared_diff=$WSH wne_zeros=$WG"

# --- 判读（甲乙丙丁＋戊通配，六把尺齐了才 ok；任何一把缺或没牙 ⇒ fail，不写"过了"）---
WOK=1
[ "$WPOS_N" = 0 ] || WOK=0
[ "$WG" = 0 ] || WOK=0
[ "$((NU - MU))" = 1 ] || WOK=0
[ "$WSH" = 0 ] || WOK=0
[ "$WRM" = 0 ] || WOK=0
[ -n "$UNIV" ] && [ "$JOBN" = "$((UNIV + 1))" ] || WOK=0         # 通配那侧＝具体类型数(含刚插的那个)，再加一条具名规则
[ -n "$INSD" ] && [ "$VRFD" = "$JOBN" ] || WOK=0                  # 回读自查覆盖到每一个工作项
[ "$((INSD + MERGE_N))" = "$JOBN" ] || WOK=0                      # 插入＋并入 == 计划项数
[ "$WAD" = "$((UNIV + 1))" ] || WOK=0                             # ★独立证人：dump 出来的三元组增量与"我算的展开数"相等
[ "$WOK" = 1 ] || echo "[x] 通配那一格的六项核对里有不等的：见上面 WILD_SUMMARY 行"
SH=$(diff <(head -"$NB" t_after.txt) <(grep -a '^TMAP ' t_before.txt) | grep -ac '^[<>]')
AD=$(comm -13 <(grep -v '^DUMP_' t_A.txt|sort) <(grep -v '^DUMP_' t_B.txt|sort) | grep -ac .)
RM=$(comm -23 <(grep -v '^DUMP_' t_A.txt|sort) <(grep -v '^DUMP_' t_B.txt|sort) | grep -ac .)
NEWM=$(md5sum ti_shell.pol 2>/dev/null | cut -d' ' -f1)
SH93=0; [ "$NEWM" = "$WANTNEW" ] && SH93=1
RTD=$(diff <(grep -a '^TMAP ' t_after.txt) <(grep -a '^TMAP ' t_after2.txt) | grep -ac '^[<>]')
echo "TI_SUMMARY rows_added=$((NA - NB)) shared_diff=$SH avtab=+$AD/-$RM shell93_md5_same=$SH93 neg_zeros=$NG rt_diff=$RTD wild_ok=$WOK wild_neg_zeros=$WG"
if [ "$((NA - NB))" = 1 ] && [ "$SH" = 0 ] && [ "$AD" = 2 ] && [ "$RM" = 0 ] \
   && [ "$SH93" = 1 ] && [ "$NG" = 0 ] && [ "$RTD" = 0 ] && [ "$WOK" = 1 ] && [ "$WG" = 0 ]; then
    echo "TI_VERDICT=ok"
    exit 0
fi
echo "TI_VERDICT=fail"
exit 9
