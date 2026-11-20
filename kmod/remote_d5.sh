#!/bin/bash
# 问 clang 要"当前树上 struct module 的真实数值"(d5.c)。
# 用法：bash /home/lucy/remote_d5.sh <树目录>   —— 先把头文件置成想要的状态再跑。
LOG=/home/lucy/d5.log
exec > "$LOG" 2>&1
TREE=${1:-/root/k/nothing_sm7325_v_mr}
cd "$TREE" || exit 1
echo "TREE=$TREE  HEAD=$(git rev-parse --short HEAD)"
echo "--- module.h 有没有打过补丁:"; grep -c __pad_vivo_mod include/linux/module.h
M=$TREE/_d5; rm -rf "$M"; mkdir -p "$M"
cp /home/lucy/d5.c "$M/"
printf 'obj-m += d5.o\n' > "$M/Makefile"
TOOL="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip RANLIB=llvm-ranlib"
make $TOOL M="$M" modules 2>&1 | grep -E "d5.c:[0-9]+" | grep -oE "d5.c:[0-9]+:[0-9]+: (error|warning).*char \(\*\)\[[0-9]+\]"
echo "END $(date)"
