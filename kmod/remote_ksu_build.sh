#!/bin/bash
# 编 KSU 的 LKM 形态（路线 B 的 API 移植波）。
# 关键点(踩过)：① CONFIG_KSU=m 必须从命令行喂，否则 obj-$(CONFIG_KSU) 全空 ⇒ MODPOST 0 modules 且 rc=0(假成功)
#             ② 必须 CC=clang + LLVM-*，否则 gcc 在 -mno-global-merge 上打死每个文件
#             ③ KCFLAGS 带空格必须走脚本，命令行里传会被吞成 -include/home/...
LOG=/home/lucy/ksu_build.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
MDIR=/root/k/ksu/kernel
cd "$MDIR" || exit 1
make -C "$KDIR" M="$MDIR" src="$MDIR" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
echo "=== error 行 ==="; grep -E ' error: ' "$LOG" | sed 's/.* error: //' | sort | uniq -c | sort -rn | head -25
echo "=== 产物 ==="; ls -l "$MDIR"/*.ko 2>/dev/null
