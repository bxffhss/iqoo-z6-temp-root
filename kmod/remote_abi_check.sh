#!/bin/bash
# 在 hermes-remote 上用刚搭好的树编 abi_check.ko。
# 判据：**编得过** = 这棵树与设备 ABI 一致(可以拿来编 KSU)；编不过 = 错误里会直接点名
# 是哪一条 BUILD_BUG_ON、实际偏移/尺寸是多少。
set -eo pipefail
TREE=/root/k/linux-5.4.281
M=/root/k/abicheck
[ -d "$TREE/include/config" ] || { echo "[x] 树还没 prepare 完(先跑 remote_setup.sh)"; exit 1; }
mkdir -p "$M"
cp /home/lucy/abi_check.c "$M/abi_check.c" 2>/dev/null || cp "$TREE/../abi_check.c" "$M/" 2>/dev/null || {
  echo "[x] 远端没有 abi_check.c(用 cli.py put 上传)"; exit 1; }
printf 'obj-m += abi_check.o\n' > "$M/Makefile"

cd "$TREE"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=clang CC=clang \
     M="$M" modules 2>&1 | tail -25
echo "=== 产物 ==="
ls -l "$M"/abi_check.ko 2>&1
echo "ABI_CHECK_OK"
