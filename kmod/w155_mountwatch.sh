#!/system/bin/sh
# w155_mountwatch.sh —— **挂载看门狗探针(取样器)**：把"bind 会不会在窗口中途被系统自愈弄坏"
# 从二手故事(Z5 教程正文)变成**本机一手**。用法：由驱动经 `@sushd:` 派发一次即可。
#
# ★为什么必须 setsid + 立刻退出：root agent(sushd)是**串行队列**(§6.141 一手：C 段那一格排在
#   D 块后面等了 6 分钟)。如果这个取样器占着队列跑 30 分钟，整条验收链就断了。
#   ⇒ 本脚本只负责**把循环甩出去**然后马上 return，循环自己写自己的文件、不接任何管道。
# ★循环里**绝不 cat 自己的输出**(`exec >"$L"` + `cat "$L"` = 自喂写满两边磁盘，例 34)。
D=/data/local/tmp
[ -f "$D/w155_mwloop.sh" ] || { echo "MW-ERR 没有 w155_mwloop.sh"; exit 1; }
rm -f "$D/w155_mw.out"
setsid sh "$D/w155_mwloop.sh" >/dev/null 2>&1 < /dev/null &
echo "MW-LAUNCHED up=$(cut -d' ' -f1 /proc/uptime) pid=$!"
exit 0
