#!/bin/bash
# 生成 av_permissions.h（它不是签入的源文件，是 security/selinux/Makefile 用 genheaders 生成的），
# 然后重编 KSU。§6.6 的下一发。
LOG=/home/lucy/ksu_round7.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
SH=/home/lucy/kshim
T="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy"

echo "=== 0) 现状: 该文件在不在"
find "$KDIR/security/selinux" -name 'av_permissions.h' | head -2
grep -n 'av_permissions\|genheaders' "$KDIR/security/selinux/Makefile" | head -8

echo; echo "=== 1) 试着用 kbuild 生成它(三种目标写法挨个试)"
for tgt in security/selinux/av_permissions.h security/selinux/genheaders security/selinux/; do
  echo "--- make $tgt"
  make -C "$KDIR" $T "$tgt" -j8 2>&1 | tail -4
  G=$(find "$KDIR" -name 'av_permissions.h' 2>/dev/null | head -1)
  [ -n "$G" ] && { echo "  生成成功: $G ($(wc -l < "$G") 行)"; break; }
done
G=$(find "$KDIR" -name 'av_permissions.h' 2>/dev/null | head -1)
[ -n "$G" ] && { cp "$G" "$SH/av_permissions.h"; cp "$G" "$SH/security/av_permissions.h" 2>/dev/null; }
echo "--- shim 目录里现在有什么:"; ls "$SH" "$SH/security" 2>/dev/null | head

echo; echo "=== 2) 重编 KSU"
cd "$M" || exit 1
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m $T STRIP=llvm-strip \
  KCFLAGS="-I$SH -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
echo "=== 剩余 error(按种类):"
grep -E ' error: ' "$LOG" | sed 's/.* error: //' | sort | uniq -c | sort -rn | head -12
echo "=== 产物:"; ls -l "$M"/kernelsu.ko 2>/dev/null || echo "(还没有 kernelsu.ko)"
echo "END $(date)"
