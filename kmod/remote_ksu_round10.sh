#!/bin/bash
# 目标: 让 check_ko.py 的三条不对变对 —— vermagic / __cfi_check / __versions CRC。
LOG=/home/lucy/ksu_round10.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
echo "START $(date)"

echo "=== 1) 装设备的 Module.symvers(否则 __versions 的 CRC 全是本树的, 上机就 disagreements) ==="
ls -l /home/lucy/Module.symvers_dev
wc -l < /home/lucy/Module.symvers_dev
cp /home/lucy/Module.symvers_dev "$KDIR/Module.symvers"
echo "  已装为 $KDIR/Module.symvers"

echo; echo "=== 2) vermagic 逐字对齐设备: 5.4.281-qgki-g2a88cd145def ==="
echo "  改前 kernel.release = $(cat $KDIR/include/config/kernel.release 2>/dev/null)"
grep -nE '^(SUBLEVEL|EXTRAVERSION)' "$KDIR/Makefile"
sed -i 's/^SUBLEVEL = 289/SUBLEVEL = 281/' "$KDIR/Makefile"
echo "  改后 Makefile: $(grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL) ' "$KDIR/Makefile" | tr '\n' ' ')"
"$KDIR"/scripts/config --file "$KDIR/.config" --set-str LOCALVERSION "-qgki-g2a88cd145def" --disable LOCALVERSION_AUTO
cd "$KDIR" || exit 1
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld prepare -j32 > /tmp/prep.log 2>&1
echo "  make prepare rc=$?  kernel.release = $(cat include/config/kernel.release)"

echo; echo "=== 3) 把 accept-all 的 __cfi_check 编进模块(本机 CFI 非 permissive 的逃生口) ==="
cp /home/lucy/cfi_stub.c "$M/cfi_stub.c"
grep -n '__cfi_check' "$M/cfi_stub.c" | head -3
python3 - <<'PY'
import re
p = "/root/k/ksu/kernel/Kbuild"
s = open(p, encoding="utf-8", errors="replace").read()
if "cfi_stub.o" in s:
    print("  已加过 cfi_stub.o")
else:
    n = len(re.findall(r"^kernelsu-objs \+= core/init\.o$", s, re.M))
    if n == 1:
        s = re.sub(r"^(kernelsu-objs \+= core/init\.o)$",
                   r"\1\nkernelsu-objs += cfi_stub.o   # 自带 accept-all __cfi_check(md §6.7; 本机 CFI 非 permissive)",
                   s, count=1, flags=re.M)
        open(p, "w", encoding="utf-8", newline="\n").write(s)
        print("  Kbuild 已加 cfi_stub.o")
    else:
        print(f"  !! 锚点命中 {n} 次, 不动")
PY

echo; echo "=== 4) 重编 + 取回两个漏掉的桩的声明 ==="
cd "$M" || exit 1
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I/home/lucy/kshim -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
ls -l "$M"/kernelsu.ko 2>/dev/null
echo "--- vermagic(modinfo):"; /usr/bin/llvm-objcopy --dump-section=.modinfo=/dev/stdout "$M/kernelsu.ko" 2>/dev/null | tr '\0' '\n' | grep -E 'vermagic|license' | head -3
echo "--- 有没有 __cfi_check:"; llvm-nm "$M/kernelsu.ko" 2>/dev/null | grep -E '__cfi_check' | head -2
echo "--- handle_sepolicy / apply_kernelsu_rules 的声明与调用点:"
grep -rnE 'handle_sepolicy|apply_kernelsu_rules' "$M" --include=*.c --include=*.h | head -8
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc2.ko 2>/dev/null && md5sum /home/lucy/kernelsu_rc2.ko
echo "END $(date)"
