#!/usr/bin/env bash
LOG=/home/lucy/ksu_rc78.log
exec > "$LOG" 2>&1
set -o pipefail
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
echo "START(rc78) $(date)"
echo "sucompat.c md5=$(md5sum $M/feature/sucompat.c | cut -d' ' -f1) 行=$(wc -l < $M/feature/sucompat.c)"
cd "$M" || exit 1
find "$M" -name '*.o' -delete
rm -f "$M"/kernelsu.ko "$M"/kernelsu.mod "$M"/kernelsu.mod.c "$M"/Module.symvers 2>/dev/null
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-include /home/lucy/ksu_compat54.h" \
  modules -j32
RC=$?
echo "MAKE_RC=$RC"
grep -E ' error: ' "$LOG" | sed 's/.* error: /ERR: /' | sort -u | head -15
if [ ! -f "$M/kernelsu.ko" ]; then echo "!! 没产物"; echo "END $(date)"; exit 1; fi
ls -l "$M/kernelsu.ko"
md5sum "$M/kernelsu.ko"
echo "END $(date)"
