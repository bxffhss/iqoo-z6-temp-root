#!/system/bin/sh
# @sushd: 只能给"一个 token"(守护按空格切词，§6.100④) ⇒ 要把内核快照抄成 shell 读得到的一份，
# 就得把 cp+chmod 写进脚本，cmd 只填脚本路径。
S=/data/local/tmp/w100_slots.txt
cat /proc/ksu_slots >"$S" 2>&1
chmod 666 "$S"
echo "抄了 $(wc -c <$S) 字节" >/data/local/tmp/w100_slots.done
