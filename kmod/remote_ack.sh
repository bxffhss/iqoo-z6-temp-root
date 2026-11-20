#!/bin/bash
# 换树：mainline 5.4.281 里没有 CONFIG_CFI_CLANG 这个符号(它是 Android Common Kernel 的下游特性)，
# 所以 olddefconfig 会把它当未知项丢掉 ⇒ struct module 少 64 字节 ⇒ 编出来的模块上机会被越界写坏。
# 这里改用 aosp-mirror/kernel_common 的 android12-5.4 分支，重跑同一组硬断言。
set -eo pipefail
CL=/root/clangrepo/clang-r383902b/bin/clang
TREE=/root/k/ack
M=/root/k/abicheck_ack

echo "== 1. 拉 ACK android12-5.4(单分支浅克隆) =="
[ -d "$TREE/.git" ] || git clone --depth 1 --single-branch -b android12-5.4 \
    https://github.com/aosp-mirror/kernel_common "$TREE" 2>&1 | tail -3
cd "$TREE"
head -4 Makefile | tr -s ' '

echo "== 2. 用设备的 config + 厂商 clang 重新配置 =="
cp /root/k/config_dev.txt .config
./scripts/config --file .config --set-str LOCALVERSION "-qgki-g2a88cd145def" \
                 --disable LOCALVERSION_AUTO
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC="$CL" olddefconfig >/dev/null
echo "--- CFI 相关符号(这次必须在):"
grep -E '^CONFIG_CFI|^# CONFIG_CFI' .config || echo "!! 仍然没有 CONFIG_CFI"
echo "--- 树自己的版本:"
make ARCH=arm64 -s kernelrelease || true

echo "== 3. prepare =="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC="$CL" -j"$(nproc)" prepare 2>&1 | tail -4
echo "kernel.release = $(cat include/config/kernel.release)"

echo "== 4. 换上我们离线抽的 Module.symvers(CRC 来源) =="
cp /root/k/linux-5.4.281/Module.symvers ./Module.symvers
wc -l ./Module.symvers

echo "== 5. 编 abi_check(10 条硬断言：负长度数组，clang 无法忽略) =="
mkdir -p "$M"; cp /home/lucy/abi_check.c "$M/"
printf 'obj-m += abi_check.o\n' > "$M/Makefile"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC="$CL" M="$M" modules 2>&1 | tail -22
ls -l "$M/abi_check.ko"
cp "$M/abi_check.ko" /home/lucy/abi_check_ack.ko
echo "ACK_ABI_DONE"
