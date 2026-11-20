#!/bin/bash
A=/home/lucy/kernelsu_rc67.ko
B=/home/lucy/kernelsu_rc71.ko
/usr/bin/llvm-nm -C "$A" 2>/dev/null | awk '{print $2, $3}' | sort > /tmp/nm67.txt
/usr/bin/llvm-nm -C "$B" 2>/dev/null | awk '{print $2, $3}' | sort > /tmp/nm71.txt
echo "rc67 符号行=$(wc -l < /tmp/nm67.txt)  rc71 符号行=$(wc -l < /tmp/nm71.txt)"
echo "--- 只在 rc71 里有的(前 12 行) ---"; comm -13 /tmp/nm67.txt /tmp/nm71.txt | head -12
echo "--- 只在 rc67 里有的(前 12 行) ---"; comm -23 /tmp/nm67.txt /tmp/nm71.txt | head -12
echo "计数: 新只有=$(comm -13 /tmp/nm67.txt /tmp/nm71.txt | wc -l) 旧只有=$(comm -23 /tmp/nm67.txt /tmp/nm71.txt | wc -l)"
echo "--- 段大小对比 ---"
for f in $A $B; do echo "## $(basename $f)"; /usr/bin/llvm-readelf -S "$f" 2>/dev/null | awk '$1 ~ /^\[/ {print $2, $6}' | paste -sd' ' - | cut -c1-300; done
echo END
