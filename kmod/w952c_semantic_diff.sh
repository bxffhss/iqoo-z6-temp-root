#!/bin/bash
# w952c_semantic_diff.sh — #213 的合格线换成**语义等价**之后，第一次真量（带"仪器必须有牙"的断言）。
#   ★上一版(w952b)报的"双向差=0"是**假的**：它用 `sesearch -A -N -C`(无效旗标)和 `seinfo --stat`(不存在)
#     ⇒ 两边都倒出**空文件** ⇒ 0 与 0 相等。这正是例 184①("证人放在两种形状都写不进的位置")的形状，
#     所以这一版把"每个读数都必须非空、且厂商侧要数得出那个已知量级(allow≈72,813)"写成硬断言。
#   合格线：①语义 base(我们手上 5 份 .cil＋30.0 mapping 用 secilc 重编) 与厂商件**双向差分=0**
#          ②过了 ① 才允许在 base 上叠我们的 delta，且 delta 件的差分必须**恰好等于**我们加的那几条。
set -u
cd /home/lucy/pol2 || exit 2
V=precompiled_sepolicy
nonempty() { # $1=文件 $2=标签 $3=最少行数
  local n; n=$(wc -l < "$1")
  if [ "$n" -lt "$3" ]; then echo "  [BAD] $2 只有 $n 行(期望≥$3) ⇒ 读数无效，不比"; return 1; fi
  echo "  [OK] $2 行数=$n"; return 0;
}
collect() { # $1=件 $2=标签
  local P=$1 T=$2 rc=0
  sesearch --allow     "$P" 2>/dev/null | sort > $T.allow.txt
  sesearch --auditallow "$P" 2>/dev/null | sort > $T.audit.txt
  sesearch --dontaudit  "$P" 2>/dev/null | sort > $T.dont.txt
  sesearch --allowxperm "$P" 2>/dev/null | sort > $T.xperm.txt
  seinfo -t "$P" 2>/dev/null | sort > $T.types.txt
  seinfo -a "$P" 2>/dev/null | sort > $T.attrs.txt
  seinfo -r "$P" 2>/dev/null | sort > $T.roles.txt
  seinfo -u "$P" 2>/dev/null | sort > $T.users.txt
  seinfo -c "$P" 2>/dev/null | sort > $T.classes.txt
  seinfo --category "$P" 2>/dev/null | sort > $T.cats.txt
  seinfo --constrain "$P" 2>/dev/null | sort > $T.constr.txt
  seinfo --validatetrans "$P" 2>/dev/null | sort > $T.vt.txt
  seinfo --permissive "$P" 2>/dev/null | sort > $T.perm.txt
  seinfo --fs_use "$P" 2>/dev/null | sort > $T.fsuse.txt
  seinfo --genfscon "$P" 2>/dev/null | sort > $T.genfs.txt
  seinfo --initialsid "$P" 2>/dev/null | sort > $T.isid.txt
  python3 -c "
import sys; from setools import PolicyFile
p=PolicyFile('$P')
print('policybenchver=%s policyvers=%s mmaps=%s handle_unknown=%s' % (p.policybenchver, p.policyvers, p.mls, p.handle_unknown))
print('bools=%d classes=%d cats=%d types=%d attrs=%d roles=%d users=%d sens=%d' % (len(list(p.bools)),len(list(p.classes)),len(list(p.categories)),len(list(p.types)),len(list(p.attributes)),len(list(p.roles)),len(list(p.users)),len(list(p.sensitivities))))
" > $T.summary.txt 2>&1
  nonempty $T.allow.txt  "$T allow"     50000 || rc=1
  nonempty $T.types.txt  "$T types"     1000  || rc=1
  nonempty $T.classes.txt "$T classes"  10    || rc=1
  echo "  [$T] summary: $(cat $T.summary.txt)"
  return $rc
}
cmp_dim() { # $1=文件后缀 $2=显示名
  local a=vendor$1 b=ours$1
  [ -s $a ] || { echo "  [SKIP] $2 厂商侧空"; return 1; }
  local only_v only_o; only_v=$(comm -23 $a $b | wc -l); only_o=$(comm -13 $a $b | wc -l)
  echo "  [$2] 只在厂商=$only_v 只在我们=$only_o"
  [ "$only_v" = 0 ] && [ "$only_o" = 0 ]
}
echo "C0 date=$(date -Is) secilc_ver=$(dpkg -l libsepol1 2>/dev/null | tail -1 | awk '{print $3}') setools=$(python3 -c 'import setools;print(setools.__version__)' 2>&1)"
echo "C1 编语义 base（★输入面只喂 30.0 那两枚 mapping＝AOSP 的 precompiled 规则）:"
rm -f ours.bin
secilc -m -M true -G -N -c 30 plat_sepolicy.cil mapping_system/30.0.cil mapping_system/30.0.compat.cil \
       plat_pub_versioned.cil vendor_sepolicy.cil system_ext_sepolicy.cil product_sepolicy.cil -o ours.bin 2>C1.err
echo "   rc=$? bytes=$(wc -c < ours.bin 2>/dev/null) md5=$(md5sum ours.bin 2>/dev/null | cut -c1-8)（厂商 $(wc -c < $V) B/$(md5sum $V | cut -c1-8)）；err 首行: $(head -1 C1.err)"
[ -s ours.bin ] || { echo "CZ_END 编不出来 ⇒ 未测"; exit 3; }
echo "C2 两侧读数（每个都要非空才算有判别力）:"
collect $V vendor; RV=$?
collect ours.bin ours; RO=$?
if [ "$RV" != 0 ] || [ "$RO" != 0 ]; then echo "CZ_END 读数无效(仪器没牙) ⇒ 不比"; exit 3; fi
echo "C3 逐维双向差分（★全 0 才叫'等价 base'）:"
ALL=1
for d in ".allow.txt:allow 规则" ".audit.txt:auditallow" ".dont.txt:dontaudit" ".xperm.txt:allowxperm" \
         ".types.txt:类型" ".attrs.txt:属性" ".roles.txt:角色" ".users.txt:用户" ".classes.txt:类" \
         ".cats.txt:类别(category)" ".constr.txt:constraint" ".vt.txt:validatetrans" ".perm.txt:permissive" \
         ".fsuse.txt:fs_use" ".genfs.txt:genfscon" ".isid.txt:initial sid"; do
  cmp_dim "${d%%:*}" "${d##*:}" || ALL=0
done
echo "C4 汇总读数对比:"; diff vendor.summary.txt ours.summary.txt | sed 's/^/   /'
echo "CZ_END date=$(date -Is) 等价 base = $([ $ALL = 1 ] && echo '★★是（可以谈 delta）' || echo '否（差分非 0，绝不装载）')"
