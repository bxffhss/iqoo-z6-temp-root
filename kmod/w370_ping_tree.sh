#!/bin/bash
echo "date=$(date '+%F %T') host=$(hostname)"
echo "--- /root/k 下有什么 ---"; ls /root/k 2>&1 | head -10
echo "--- /root/k/ksu 顶层 ---"; ls /root/k/ksu 2>&1 | head -8
echo "--- /root/k/ksu/kernel 存在? ---"; ls /root/k/ksu/kernel 2>&1 | head -12
echo "--- 出货那份 .ko 还在? ---"; ls -l /root/k/ksu/kernel/kernelsu.ko /home/lucy/kernelsu_rc67.ko /home/lucy/kernelsu_rc69.ko 2>&1 | head -6
echo "--- klog.h 到底在哪 ---"; find /root/k/ksu -name klog.h 2>/dev/null | head -3
echo "--- selinux_util.c 在哪 ---"; find /root/k/ksu -name "selinux_util.c" 2>/dev/null | head -3
echo END
