#!/bin/bash
# 路线 B 的决定性试验：把 ACK 5.4.281 树配成与设备同形的 **LTO_CLANG + THINLTO + CFI_CLANG**，
# 看 10 条硬断言能不能全过、外部模块能不能编出来。
# 为什么可能成：CFI 的老式 clang 实现(-fsanitize=cfi)Debian clang 14 支持；
#   而"模块被内核回调时的校验"我们已经实测可以用**自带的 accept-all __cfi_check** 绕过，
#   所以"模块不必用同款 clang 编"这一条是站得住的(前提：struct 布局对得上)。
LOG=/home/lucy/ack3.log
exec > "$LOG" 2>&1
echo "START $(date)"
TREE=/root/k/ack
M=/root/k/abicheck_ack
CL=clang                       # Debian 12 的 clang 14(支持 -fsanitize=cfi)

cd "$TREE" || { echo "NO TREE"; exit 1; }
apt-get install -y -qq llvm ld-lld >/dev/null 2>&1 || apt-get install -y -qq llvm lld >/dev/null 2>&1
echo "clang: $(clang --version | head -1)"; echo "ld.lld: $(ld.lld --version 2>/dev/null | head -1)"

cp /root/k/config_dev.txt .config
./scripts/config --file .config --set-str LOCALVERSION "-qgki-g2a88cd145def" \
  --disable LOCALVERSION_AUTO \
  --enable LTO --enable LTO_CLANG --enable THINLTO \
  --enable CFI_CLANG --enable CFI_CLANG_SHADOW --disable CFI_PERMISSIVE \
  --enable KALLSYMS

TOOL="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC=$CL LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip RANLIB=llvm-ranlib"
make $TOOL olddefconfig >/dev/null 2>&1
echo "--- CFI/LTO 是否留下了:"
grep -E '^CONFIG_CFI|^CONFIG_LTO|^CONFIG_THINLTO' .config

make $TOOL -j"$(nproc)" prepare 2>&1 | tail -6
echo "kernel.release = $(cat include/config/kernel.release 2>/dev/null)"
cp /root/k/linux-5.4.281/Module.symvers ./Module.symvers

mkdir -p "$M"; cp /home/lucy/abi_check.c "$M/"
printf 'obj-m += abi_check.o\n' > "$M/Makefile"
make $TOOL M="$M" modules 2>&1 | tail -25
if [ -f "$M/abi_check.ko" ]; then
  cp "$M/abi_check.ko" /home/lucy/abi_check_ack.ko
  echo "ACK_ABI_OK —— 10 条硬断言全过，这棵树可以拿来编 KSU"
else
  echo "ACK_ABI_FAIL"
fi
echo "END $(date)"
echo "=== 日志尾部 ==="
tail -30 "$LOG"
