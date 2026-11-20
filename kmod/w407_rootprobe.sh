#!/system/bin/sh
# w407_rootprobe.sh —— #124 那两笔"只有 root 窗才能做"的读数，放在**收尾路径**里跑(不污染被判据的窗口形状)。
#   为什么要它(一手账 md §6.329)：
#     1) `/data/system/packages.list` 从 shell 一直读不到(§6.324⑤：干净基线下也 Permission denied)，
#        而 ko 的名单 prune 与观察者都吃这张表 ⇒ "suw 被 disable 之后它的行还在不在"这一维从来没有一手读数。
#        ★这一维已经**不再卡结论**(19/21 两份整环 dump 盖到 load+1.4 秒、里面 `load_allow_uid` 在而 `prune uid` 不在，
#        而实测 prune 发生在 load+0.099~0.108 秒)——所以这条腿是**补档案**，不是**补证据**，不许为它单开一发。
#     2) `/data/local/tmp/kd`(改道落点，`apk_data_file` 标签)在基线态 shell 连 `mv`/`:` 都被拒 ⇒ 只能 root 侧删。
#     3) 顺带把 `/data/adb` 实况整份留证(Manager 会自己重装 ksud，§6.236)。
#   ★跑在 teardown 里(root 通道此时已证还活着：第 22 发 `CLEAN2 up=2940.51 uid=0`)。
L=/data/local/tmp/w407_rootprobe.out
PKGS=/data/system/packages.list
{
    echo "=== ROOTPROBE up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) ==="
    echo "A) packages.list：$(ls -lZ $PKGS 2>&1 | tr -s ' ')"
    if [ -r "$PKGS" ]; then
        N=$(wc -l < "$PKGS")
        echo "   ★总行数=$N(root 侧第一次真读到；shell 侧历来 EACCES)"
        echo "   字段数分布(前 6 个)：$(awk '{print NF}' "$PKGS" | sort | uniq -c | sort -rn | head -6 | tr '\n' ' ')"
        echo "   ★短行(NF<4)条数=$(awk 'NF < 4 {c++} END {print c+0}' "$PKGS")；第一条短行的行号=$(awk 'NF < 4 {print NR; exit}' "$PKGS")"
        echo "   logd 抱怨过的那一行(:878 too few fields)实况：$(sed -n '878p' "$PKGS" | cat -A | cut -c1-120)"
        for p in com.suw.manager com.termux me.weishu.kernelsu; do
            echo "   [$p] $(grep -a "^$p " "$PKGS" || echo '★不在表里')"
        done
        echo "   表里 uid=10342 的行：$(awk '$2 == 10342 {print; exit}' "$PKGS" | cut -c1-140)(空⇒没有第二家用这个 uid)"
    else
        echo "   ★读不到(不是意外，但如果这条腿在 root 下还读不到，那就是新事实，别当没测到)"
    fi
    echo "B) 同一时刻的框架侧口径(和 A 对照用，别互相顶替)："
    dumpsys package com.suw.manager 2>/dev/null | grep -aE 'userId=|enabled=|stopped=|masked=' | head -6 | sed 's/^/   /'
    echo "   pm 现取 uid：$(pm list packages -U 2>/dev/null | grep -a -w package:com.suw.manager)"
    echo "C) /data/adb 整份实况：$(ls -laR /data/adb 2>&1 | tr '\n' '|' | cut -c1-320)"
    echo "D) 改道落点 kd：删之前=$(ls -lZ /data/local/tmp/kd 2>&1 | tr -s ' ' | cut -c1-90)"
    rm -f /data/local/tmp/kd 2>&1 | sed 's/^/   rm 回执：/'
    echo "   ★删之后=$(ls -lZ /data/local/tmp/kd 2>&1 | tr -s ' ' | cut -c1-90)(还在⇒标签不是唯一挡路的，这句要改)"
    echo "=== DONE ==="
} > "$L" 2>&1
chmod 666 "$L"
