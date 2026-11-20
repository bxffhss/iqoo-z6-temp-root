#!/bin/bash
# 用 ACK 的 **android12-5.4.281_r00** tag(与设备 5.4.281-qgki 同 LTS 基线)，
# 配厂商 clang r383902b，重跑 10 条硬断言。
# 全程写日志到 /home/lucy/ack2.log —— 上一版就是靠 stdout 回传，中途失败时什么都看不到。
# 注意：这里**故意不用 set -e** —— 上一版开了它，`git checkout` 之后任何一步的非零退出
# 都会静默终止整个脚本，只剩一个看不懂的 exit code。改成"每步自己打印结果 + 最后看日志"。
LOG=/home/lucy/ack2.log
exec > "$LOG" 2>&1
echo "START $(date)"
CL=/root/clangrepo/clang-r383902b/bin/clang
TREE=/root/k/ack
M=/root/k/abicheck_ack

echo "== 1. 切到 android12-5.4.281_r00 =="
cd "$TREE"
git fetch --depth 1 origin tag android12-5.4.281_r00
git checkout --force android12-5.4.281_r00
head -5 Makefile | tr -s ' ' | grep -E 'VERSION|PATCHLEVEL|SUBLEVEL'

echo "== 2. 设备 config + 厂商 clang 配置 =="
cp /root/k/config_dev.txt .config
./scripts/config --file .config --set-str LOCALVERSION "-qgki-g2a88cd145def" \
                 --disable LOCALVERSION_AUTO
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC="$CL" olddefconfig >/dev/null
echo "--- 关键判据: CFI 符号在不在(不在就说明树或编译器还不对)"
grep -E '^CONFIG_CFI|^# CONFIG_CFI' .config || echo "!! 没有 CONFIG_CFI"

echo "== 3. prepare =="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC="$CL" -j"$(nproc)" prepare 2>&1 | tail -4
echo "kernel.release = $(cat include/config/kernel.release)"

echo "== 4. 换上离线 Module.symvers =="
cp /root/k/linux-5.4.281/Module.symvers ./Module.symvers
wc -l ./Module.symvers

echo "== 5. 编 abi_check =="
mkdir -p "$M"; cp /home/lucy/abi_check.c "$M/"
printf 'obj-m += abi_check.o\n' > "$M/Makefile"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC="$CL" M="$M" modules 2>&1 | tail -25
if [ -f "$M/abi_check.ko" ]; then
  cp "$M/abi_check.ko" /home/lucy/abi_check_ack.ko
  ls -l /home/lucy/abi_check_ack.ko
  echo "ACK_ABI_OK(10 条硬断言全过)"
echo "END $(date)"
else
  echo "ACK_ABI_FAIL"
echo "END $(date)"
fi

echo "--- 日志尾部(供 cli.py 回传时直接看):"
tail -30 "$LOG"
