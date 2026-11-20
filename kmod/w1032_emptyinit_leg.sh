#!/system/bin/sh
# w1032_emptyinit_leg.sh —— 第 76 发：装「同料、空 init」件(w1031_emptyinit.ko)。
# 只问一件事：把这份 SS 子集**链进模块**这件事本身(装载期：重定位/__versions/ftrace/CFI shadow)会不会炸这台机。
# ★每步之前 sync；判语三分支含"没装进去但机器活着"＝未测(第 75 发的教训)。
L=/data/local/tmp/w1032_empty.out
K=/data/local/tmp/w1031_emptyinit.ko
MD5_EXPECT=5fdcc64991a308188fcb57a214a8c43d
: > $L
echo "BEGIN up=$(cat /proc/uptime) enf=$(getenforce) id=$(id)" >> $L
sync
M=$(md5sum $K 2>/dev/null | cut -d' ' -f1)
echo "ko_bytes=$(wc -c < $K 2>/dev/null) ko_md5=$M expect=$MD5_EXPECT" >> $L
sync
if [ "$M" != "$MD5_EXPECT" ]; then echo "EVI_VERDICT=未测(md5 不符 ⇒ 不 insmod)" >> $L; sync; exit 1; fi
echo "ARGV=insmod $K" >> $L
sync
insmod $K
RC=$?
echo "insmod_rc=$RC" >> $L
sync
NM=$(grep -c '^w985_probe ' /proc/modules)
STG=$(cat /sys/module/w985_probe/parameters/rt_stage 2>&1)
echo "IN_MODULES=[$NM] rt_stage=[$STG]" >> $L
sync
if [ "$NM" = 1 ]; then
  echo "EVI_VERDICT=判正(同料空 init 装得进去 ⇒ 装载期无罪；第 72/73 发的复位需要 init 真去跑那些步骤才出现)" >> $L
elif [ "$RC" = 0 ]; then
  echo "EVI_VERDICT=未测(insmod 报 0 但 /proc/modules 里没有它 ⇒ 读数自相矛盾，别当结论)" >> $L
else
  echo "EVI_VERDICT=判负(同料空 init 也被拒 rc=$RC ⇒ 看 insmod 的 dmesg 原因；机器若活着就还没解释第 72 发)" >> $L
fi
echo "END up=$(cat /proc/uptime)" >> $L
sync
