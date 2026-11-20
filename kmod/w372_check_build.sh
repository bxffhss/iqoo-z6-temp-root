#!/bin/bash
L=/home/lucy/ksu_rc71.log
echo "=== 日志行数/字节 ==="; wc -l $L; echo "=== 闸门段(第 5 节到末尾) ==="; sed -n '/=== 5)/,$p' $L | head -40
echo "=== 产物 ==="; ls -l /home/lucy/kernelsu_rc71.ko /root/k/ksu/kernel/kernelsu.ko 2>&1
md5sum /home/lucy/kernelsu_rc71.ko /root/k/ksu/kernel/kernelsu.ko 2>&1
echo "=== make 是否真跑了(日志里 compile 行数/错误) ==="; grep -c "  CC\|  LD\|clang" $L; grep -E ' error: |Error ' $L | head -5
echo "=== START/END 两行(看时间跨度) ==="; grep -a "^START(rc71)\|^END " $L
echo END
