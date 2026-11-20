#!/bin/bash
# w952_rebuild_policy.sh — 用**设备上拉回来的完整链接输入**重造 precompiled_sepolicy，看能不能逐字节复现 `8c8729c0…`。
#   ★为什么这发值得做（§6.453 当时判"缺 build 期输入"，现在看是我漏了输入面）：
#     `analysis/policy/` 里已经有 5 份 .cil(plat/plat_pub_versioned/product/system_ext/vendor)＋mapping_system/ 12 份——
#     这正是 Android 生成 precompiled_sepolicy 的**全部** secilc 输入；当时我只喂了部分文件，差 3,980 B 就归因成"缺料"。
#   闸口径不变：**md5 逐字节相同**才有资格谈"造 patch 件＋写 /sys/fs/selinux/load"；不同就继续找输入面差额。
#   远端跑（Debian12，secilc 4.4/setools 4.4.x；4GiB 硬顶，这活只用几十 MB）。
set -u
cd /home/lucy/pol
VENDOR_MD5=8c8729c0e4a2ce41d03008cdd1ab2be9
echo "R0 date=$(date -Is) secilc=$(command -v secilc) ver=$(secilc -h 2>&1 | head -1)"
echo "R1 输入件清单（大小＋md5）:"
md5sum *.cil precompiled_sepolicy mapping_system/*.cil 2>&1 | sed 's/^/    /'
echo "R2 mapping 文件数=$(ls mapping_system/*.cil 2>/dev/null | wc -l)（含 .compat.cil）"
# Android 侧的真实调用（system/sepolicy/Android.mk 的 sepolicy_policy → precompiled）：
#   secilc -m -M true -G -c 30 plat.cil mapping/*.cil plat_pub_versioned.cil vendor.cil system_ext.cil product.cil -o out
# ★顺序有影响（名字表按读入顺序分配），所以三种排法都试，每种都现算 md5 与 vendor 比。
run() { # $1=标签 余=文件列表
  local tag=$1; shift
  rm -f out.$tag
  secilc -m -M true -G -c 30 "$@" -o out.$tag 2>err.$tag
  local rc=$?
  if [ -f out.$tag ]; then
    echo "  [$tag] rc=$rc bytes=$(wc -c < out.$tag) md5=$(md5sum out.$tag | cut -d' ' -f1) 目标=$VENDOR_MD5 $(md5sum out.$tag | grep -q $VENDOR_MD5 && echo ★★逐字节相同 || echo 不相同)"
  else
    echo "  [$tag] rc=$rc 没产出件；err 首两行: $(head -2 err.$tag | tr '\n' '|')"
  fi
}
MAPS=$(ls mapping_system/*.cil | sort | tr '\n' ' ')
echo "R3 三种喂入顺序（★都不带 -N＝打开 neverallow 检查，编得过才算等价物）:"
run A plat_sepolicy.cil $MAPS plat_pub_versioned.cil vendor_sepolicy.cil system_ext_sepolicy.cil product_sepolicy.cil
run B plat_sepolicy.cil $MAPS plat_pub_versioned.cil product_sepolicy.cil system_ext_sepolicy.cil vendor_sepolicy.cil
echo "R4 只带 30.0 那两枚 mapping（有些版本只用当前 mapping）:"
run C plat_sepolicy.cil mapping_system/30.0.cil mapping_system/30.0.compat.cil plat_pub_versioned.cil vendor_sepolicy.cil system_ext_sepolicy.cil product_sepolicy.cil
echo "R5 差分（若某支 bytes 相同再看逐字节）:"
for t in A B C; do
  [ -f out.$t ] || continue
  echo "  [$t] 与 vendor 的字节差分=$(cmp -l out.$t precompiled_sepolicy 2>/dev/null | wc -l) 行；首个不同偏移=$(cmp out.$t precompiled_sepolicy 2>&1 | head -1)"
done
echo "RZ_END date=$(date -Is)"
