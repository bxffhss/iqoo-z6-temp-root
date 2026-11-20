#!/bin/bash
# w977_rt_verdict.sh — #216 地基的判决：厂商二进制件 →(libsepol 读→原样写)→ 往返件，两者做**语义**比对。
# ★为什么不比 md5 就算完：上一轮刚学到（§6.456/例 187⑤），哈希对"重新序列化的东西"没有判别力；
#   往返件已经实测"大小相同、偏移 23 起不同"⇒ 只能问"规则集合变没变"。
# ★这条判据也直接是 #216 装载前的自检形状：以后叠了 delta 也是同一把尺子（那时允许多出来的恰好=我加的条数）。
set -u
D=/home/lucy/pol3
mkdir -p $D; cd $D || exit 2
cp /home/lucy/pol2/precompiled_sepolicy $D/ 2>/dev/null
cp /home/lucy/pol2/rt_pub.bin $D/ 2>/dev/null
for f in precompiled_sepolicy rt_pub.bin; do
  echo "  $f: bytes=$(wc -c < $f) md5=$(md5sum $f | cut -c1-8)"
done
V=$D/vendor.allow.txt; O=$D/ours.allow.txt
sesearch --allow $D/precompiled_sepolicy 2>/dev/null | sort > $V
sesearch --allow $D/rt_pub.bin        2>/dev/null | sort > $O
nv=$(wc -l < $V); no=$(wc -l < $O)
echo "T1 allow 行数：厂商=$nv 往返=$no  ★两侧都必须非空，否则读数无效"
if [ "$nv" -lt 50000 ] || [ "$no" -lt 50000 ]; then echo "TZ_END 读数无效(仪器没牙) ⇒ 不出结论"; exit 3; fi
echo "T2 三元组级双向差（★全 0 才叫「往返保真」）:"
python3 /home/lucy/w953b_rule_diff_probe.py $D 2>&1 | tail -16
rc=$?
echo "T3 差分器自身 rc=$rc（它内部还有一道「解析覆盖率≥99.9%」的闸）"
echo "T4 头部差异看一眼（偏移 23 附近，只当旁证不当结论）:"
cmp -l $D/precompiled_sepolicy $D/rt_pub.bin 2>/dev/null | wc -l | sed 's/^/   不同字节数=/'
od -c $D/precompiled_sepolicy 2>/dev/null | sed -n '1,4p' | cut -c1-100 | sed 's/^/   厂商: /'
od -c $D/rt_pub.bin 2>/dev/null | sed -n '1,4p' | cut -c1-100 | sed 's/^/   往返: /'
echo "TZ_END date=$(date -Is)"
