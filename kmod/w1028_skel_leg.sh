#!/system/bin/sh
# w1028_skel_leg.sh —— 第 75 发：装「骨架件」w1026_skel.ko(36 次手工符号解析、零 SS 代码)。
# 分岔：skel_hits 读得回来 ⇒ 解析层无罪，火力收窄到 SS 子集；照样复位 ⇒ 杀手在解析层/符号表规模，#216-B 判死。
# ★每步之前 sync(第 72/73 发的教训：没落盘的行会被硬复位吃掉，"没走到"就与"死在里面"分不开)。
L=/data/local/tmp/w1028_skel.out
K=/data/local/tmp/w1026_skel.ko
MD5_EXPECT=25cfb051d4c024211d9cbf2cbae1f344
: > $L
echo "BEGIN up=$(cat /proc/uptime) enf=$(getenforce) id=$(id)" >> $L
sync
M=$(md5sum $K 2>/dev/null | cut -d' ' -f1)
echo "ko_bytes=$(wc -c < $K 2>/dev/null) ko_md5=$M expect=$MD5_EXPECT" >> $L
sync
if [ "$M" != "$MD5_EXPECT" ]; then echo "SKEL_VERDICT=未测(md5 不符 ⇒ 不 insmod)" >> $L; sync; exit 1; fi
echo "ARGV=insmod $K" >> $L
sync
insmod $K
echo "insmod_rc=$?" >> $L
sync
HITS=$(cat /sys/module/w1026_skel/parameters/skel_hits 2>&1)
NM=$(grep -c '^w1026_skel ' /proc/modules)
echo "IN_MODULES=[$NM] skel_hits=[$HITS] (解析 36 个名字，命中数应 ≤36 且 >0)" >> $L
sync
if [ "$NM" = 1 ]; then
  # 能进 /proc/modules 就意味着 init 返回了 0 ⇒ 那 36 次 kallsyms 查找已经全部走完(没死在循环里)
  echo "SKEL_VERDICT=判正(解析层无罪：件装进去、init 跑完、36 次查找做完；skel_hits=[$HITS] 是附加信息)" >> $L
else
  echo "SKEL_VERDICT=判负(骨架件也装不进去 ⇒ 杀手在解析层/符号表规模，#216-B 判死)" >> $L
fi
echo "END up=$(cat /proc/uptime)" >> $L
sync
