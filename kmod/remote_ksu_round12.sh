#!/bin/bash
# 上一发 Kbuild 插入没生效 ⇒ 改成追加到文件末尾(那文件自己就写着"Keep a new line here!!
# Because someone may append config")。同时把 handle_sepolicy 的真实声明取回来校桩签名。
LOG=/home/lucy/ksu_round12.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
echo "START $(date)"

echo "=== 0) 桩签名核对 ==="
grep -rn 'handle_sepolicy\|apply_kernelsu_rules' "$M"/selinux/ 2>/dev/null | grep -vE 'rules\.c|sepolicy\.c' | head -6
echo "--- 我写的桩:"; grep -n 'handle_sepolicy' "$M/selinux/dropped_stub.c"

echo; echo "=== 1) Kbuild 现状 + 追加(幂等) ==="
grep -nE 'kernelsu-objs' "$M/Kbuild" | tail -6
if grep -q 'dropped_stub.o' "$M/Kbuild"; then echo "  已追加过"; else
  printf '\nkernelsu-objs += cfi_stub.o\nkernelsu-objs += selinux/dropped_stub.o\n' >> "$M/Kbuild"
  echo "  已追加 cfi_stub.o 与 selinux/dropped_stub.o"
fi
tail -4 "$M/Kbuild"
ls -l "$M/cfi_stub.c" "$M/selinux/dropped_stub.c" 2>&1 | head -3

echo; echo "=== 2) 重编(强制重链: 先删产物) ==="
rm -f "$M"/kernelsu.ko "$M"/*.o "$M"/.kernelsu.mod 2>/dev/null
cd "$M" || exit 1
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I/home/lucy/kshim -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
grep -E ' error: ' "$LOG" | sed 's/.* error: /ERR: /' | sort -u | head -8
ls -l "$M"/kernelsu.ko 2>/dev/null
echo "--- 三个符号应当变成 T(定义了)而不是 U:"
llvm-nm "$M/kernelsu.ko" 2>/dev/null | grep -E '__cfi_check|handle_sepolicy|apply_kernelsu_rules'
/usr/bin/llvm-objcopy --dump-section=.modinfo=/dev/stdout "$M/kernelsu.ko" 2>/dev/null | tr '\0' '\n' | grep vermagic
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc4.ko 2>/dev/null && md5sum /home/lucy/kernelsu_rc4.ko
echo "END $(date)"
