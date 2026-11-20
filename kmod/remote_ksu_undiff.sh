#!/bin/bash
cd /home/lucy || exit 1
for k in kernelsu_rc18.ko kernelsu_rc19.ko kernelsu_rc20.ko; do
    [ -f "$k" ] || { echo "缺少 $k"; continue; }
    /usr/bin/llvm-nm -u "$k" | awk '{print $2}' | sort -u > "$k.und"
    echo "$k: $(wc -l < "$k.und") 个未定义"
done
echo "### rc20 相对 rc19 新增的引用:"
comm -13 kernelsu_rc19.ko.und kernelsu_rc20.ko.und
echo "### __flush_dcache_area 出现在哪几版:"
grep -c '__flush_dcache_area' kernelsu_rc18.ko.und kernelsu_rc19.ko.und kernelsu_rc20.ko.und 2>/dev/null
echo "### rc20 全部未定义里, symvers 找不到的:"
while read -r s; do
    awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' /home/lucy/Module.symvers_dev || echo "  缺 CRC: $s"
done < kernelsu_rc20.ko.und
