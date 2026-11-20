#!/bin/bash
# w952b_semantic_equiv.sh — 把 #213 的"合格线"从 **md5 逐字节** 换成 **语义等价**，并当场量二者。
#   ★为什么要换线（这一发的判断，不是放宽标准）：
#     md5 相等要求"连符号表顺序、块顺序、libsepol 版本"全都一样；我们手上是 Debian 的 secilc(libsepol 3.4)，
#     厂商件是 AOSP 构建里的 libsepol 编出来的 ⇒ **序列化差异不可消除**，"3,980 B 差额"根本不是缺料。
#     而"装载上去会不会改变现有行为"这个问题，**只由语义决定**：类型/属性/规则集合、约束、级别、permissive 集合。
#   ⇒ 新合格线（比 md5 更能保护整机强制态）：
#       ①我们重建的 base 与厂商件做**双向语义差分**＝0（allow/neverallow/auditallow 三类规则集、类型数、attribute 数、
#         role、bool、level/policydb 版本）；
#       ②只有 ① 过了，才在 base 上叠我们的 .cil delta，再对"delta 件 vs 厂商件"做同一条差分 ⇒ 差出来的**必须恰好是**
#         我们加的那几条，多一条都不装。
#   装载那一步仍然：用户现场点头＋只在 Permissive 段＋回退＝重启。
set -u
cd /home/lucy/pol2 || exit 2
V=precompiled_sepolicy
MAPS=$(ls mapping_system/*.cil | sort | tr '\n' ' ')
say() { echo "$@"; }
dump() { # $1=件 $2=标签  → 产 .rules（三类规则，排序）＋计数读数
  sesearch -A -N -C "$1" 2>/dev/null | sort > "$2.rules.txt"
  seinfo --stat -c 30 "$1" 2>/dev/null | tr -d ' ' > "$2.stat.txt"
  say "  [$2] rules=$(wc -l < "$2.rules.txt") bytes=$(wc -c < "$1") md5=$(md5sum "$1" | cut -c1-8)"
}
say "S0 secilc=$(secilc -V 2>&1 | head -1) sesearch=$(command -v sesearch) seinfo=$(command -v seinfo)"
say "S1 厂商件基线读数:"
dump $V VENDOR
for cfg in "N_full:-m -M true -G -N -c 30" "N_vers:-m -M true -G -N -c 30" ; do
  tag=${cfg%%:*}; flags=${cfg#*:}
  rm -f out.$tag
  case $tag in
    N_full) secilc $flags plat_sepolicy.cil $MAPS plat_pub_versioned.cil vendor_sepolicy.cil system_ext_sepolicy.cil product_sepolicy.cil -o out.$tag 2>err.$tag ;;
    N_vers) secilc $flags plat_sepolicy.cil mapping_system/30.0.cil mapping_system/30.0.compat.cil plat_pub_versioned.cil vendor_sepolicy.cil system_ext_sepolicy.cil product_sepolicy.cil -o out.$tag 2>err.$tag ;;
  esac
  rc=$?
  if [ -s out.$tag ]; then
    say "S2 [$tag] rc=$rc 产出如下，并与厂商件双向差分:"
    dump out.$tag $tag
    say "     规则集差异行数: 只在厂商=$(comm -23 VENDOR.rules.txt $tag.rules.txt | wc -l)  只在我们=$(comm -13 VENDOR.rules.txt $tag.rules.txt | wc -l)"
    say "     stat 差异: $(diff VENDOR.stat.txt $tag.stat.txt | grep -c '^[<>]') 行"
    diff VENDOR.stat.txt $tag.stat.txt | head -12 | sed 's/^/       /'
    comm -13 VENDOR.rules.txt $tag.rules.txt | head -4 | sed 's/^/       只在我们: /'
    comm -23 VENDOR.rules.txt $tag.rules.txt | head -4 | sed 's/^/       只在厂商: /'
  else
    say "S2 [$tag] rc=$rc 没产出；err 首行: $(head -1 err.$tag)"
  fi
done
say "SZ_END date=$(date -Is)  ★判读：只有 rules 双向差=0 且 stat 差=0 的那一支，才有资格当'等价 base'叠 delta"
