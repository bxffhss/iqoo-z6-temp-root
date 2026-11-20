#!/bin/bash
# 纯构建(不动任何源文件/头文件)：flask.h 与 av_permissions.h 用**生成出来的那份**
# (在 $KDIR/security/selinux/ 下，所以 -I 那里就够，不依赖 shim 拷贝)。
LOG=/home/lucy/ksu_build_only.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7354_v_mr
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
cd "$M" || exit 1
echo "=== 用的兼容头(尾部 8 行, 确认没被改坏):"; tail -8 /home/lucy/ksu_compat54.h
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I/home/lucy/kshim -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
echo "=== 剩余 error(按种类):"
grep -E ' error: ' "$LOG" | sed 's/.* error: //' | sort | uniq -c | sort -rn | head -10
echo "=== 产物:"; ls -l "$M"/kernelsu.ko 2>/dev/null || echo "(还没有 kernelsu.ko)"
echo "END $(date)"
