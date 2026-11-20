#!/system/bin/sh
# w1107_pre_leg.sh —— 第 89 发的**第一段（只读）**：把当前运行期策略**原样导出**并落一堆身份读数。
#   ★为什么单独一段：装载(pol.new)必须发生在"离线差分已把这份导出确认为厂商件、并且把我们那份 new 证成
#     『厂商 + 恰好 3 条、零删除、零削弱』"之后。那段判定要在 PC 上跑（x86 的 w1104 件），
#     所以腿必须在这里断一刀：**这一段结构上不可能写任何策略**（没有 pol.new、没有 > /sys/fs/selinux/load）。
#   ★一条规则：一个文件只有一个写者(§6.461)。本件 $L 只有本腿写。
L=/data/local/tmp/w1107_pre.out
D=/data/local/tmp/w1107
POL=$D/pol.orig
mkdir -p $D 2>/dev/null
: > $L
echo "BEGIN up=$(cut -d' ' -f1 /proc/uptime) enforce=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)" >> $L
echo "ARM=只导出运行期策略(不装载/不写 /sys/fs/selinux/load/不翻执法)" >> $L
echo "POLICYVERS_FILE=$POL" >> $L
# --- 1) 导出（Permissive 段才读得到；执法态下这条会被拒＝§6.445②，那也是读数） ---
cat /sys/fs/selinux/policy > $POL 2>$D/export.err
RC=$?
echo "EXPORT_rc=$RC bytes=$(wc -c < $POL 2>&1) md5=$(md5sum $POL 2>&1 | cut -d' ' -f1) err=[$(head -1 $D/export.err 2>&1 | cut -c1-80)]" >> $L
# --- 2) 头 16 字节：与已知厂商件头部对表（8cff7cf9 … "SE Linux" 1e000000＝v30） ---
echo "HEAD16=$(od -An -tx1 -N16 $POL 2>&1 | tr -s ' ')" >> $L
# --- 3) ★负对照(例 194)：先证"导出真在读那个面"——把一个不存在的名走同一条 cat，必须 rc≠0 ---
cat /sys/fs/selinux/__no_such_face__ > $D/neg.tmp 2>/dev/null
NEGR=$?
rm -f $D/neg.tmp
[ "$NEGR" = 0 ] && echo "[x] 负对照：不存在的面也 rc=0 ⇒ 上面那条 EXPORT_rc 没有牙" >> $L
echo "NEG_CTRL_rc=$NEGR (必须非 0)" >> $L
# --- 4) 装载前的行为基线（★在执法翻转之前只能记"未测"，这里只记形状，不当判据） ---
echo "PRE_SYSERVER=$(pidof system_server 2>&1 | tr -s ' ' | cut -c1-40)" >> $L
echo "PRE_UP_AFTER=$(cut -d' ' -f1 /proc/uptime) enf_after=$(cat /sys/fs/selinux/enforce 2>&1)" >> $L
chmod -R a+r $D 2>/dev/null
chmod 666 $L 2>/dev/null
sync
echo "END up=$(cut -d' ' -f1 /proc/uptime) pol_md5=$(md5sum $POL 2>/dev/null | cut -d' ' -f1)" >> $L
sync
