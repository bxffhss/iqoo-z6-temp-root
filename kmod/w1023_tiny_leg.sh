#!/system/bin/sh
# w1023_tiny_leg.sh —— 第 74 发那一枪只问一件事：**这台机能不能装"任何"第二个模块**。
# 件＝w1020_tiny.ko(129,872 B；init 只 pr_info 一行；无 SS 代码、不查符号、不建 slab、不碰 /proc、不写 load)。
# ★每一步之前都 sync：第 72/73 发两次都因为"页缓存里的下一行没落盘"而分不清"没走到"与"走到但死在里面"。
L=/data/local/tmp/w1023_tiny.out
K=/data/local/tmp/w1020_tiny.ko
MD5_EXPECT=9459387abe0affebfe80375c104e6342
: > $L
echo "BEGIN up=$(cat /proc/uptime) enf=$(getenforce) id=$(id)" >> $L
sync
M=$(md5sum $K 2>/dev/null | cut -d' ' -f1)
echo "ko_bytes=$(wc -c < $K 2>/dev/null) ko_md5=$M expect=$MD5_EXPECT" >> $L
sync
if [ "$M" != "$MD5_EXPECT" ]; then echo "B2T_VERDICT=未测(md5 不符 ⇒ 不 insmod)" >> $L; sync; exit 1; fi
echo "ARGV=insmod $K" >> $L
sync
insmod $K
echo "insmod_rc=$?" >> $L
sync
echo "IN_MODULES=[$(grep -c '^w1020_tiny ' /proc/modules)] param_tiny_alive=[$(cat /sys/module/w1020_tiny/parameters/tiny_alive 2>&1)]" >> $L
sync
NM=$(grep -c '^w1020_tiny ' /proc/modules)
if [ "$NM" = 1 ]; then echo "B2T_VERDICT=判正(第二个模块装得进去 ⇒ 第 73 发的死不在『装载动作』，在我们那件的内容里)" >> $L
else echo "B2T_VERDICT=判负(极简件也装不进去 ⇒ 这条路上『装第二个模块』本身就是墙)" >> $L; fi
echo "END up=$(cat /proc/uptime)" >> $L
sync
