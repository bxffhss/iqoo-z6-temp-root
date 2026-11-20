#!/bin/bash
# 在 hermes-remote(Debian12/root/128核) 上搭一个"与设备逐字同 config"的 5.4.281 构建树。
# 目的：编 KSU 这类需要内核头/构建树的模块之前，先用它算一遍 struct 偏移，
#       与真机量到的(struct module: name@24 init@392 exit@888 size=960;
#                    struct kprobe: addr@40 symbol_name@48 size=136)对比。
#       偏移对得上 ⇒ 这棵树可以拿来编模块；对不上 ⇒ 只能继续手搓，别硬编 KSU。
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "== 0. 磁盘 =="; df -h /root | tail -1

echo "== 1. 装工具链 =="
apt-get update -qq >/dev/null
apt-get install -y -qq gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  flex bison bc libelf-dev libssl-dev cpio rsync xz-utils >/dev/null
aarch64-linux-gnu-gcc --version | head -1

echo "== 2. 取 linux-5.4.281 源码 =="
mkdir -p /root/k && cd /root/k
if [ ! -d linux-5.4.281 ]; then
  curl -sSf -o linux-5.4.281.tar.xz https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.4.281.tar.xz
  ls -l linux-5.4.281.tar.xz
  tar xf linux-5.4.281.tar.xz
fi
cd linux-5.4.281 && ls -d include/linux/module.h

echo "== 3. 用设备的 config(由 put 上传到 /root/k/config_dev.txt) =="
cp /root/k/config_dev.txt .config
>make ARCH=arm64 olddefconfig >/dev/null 2>&1 || \
  make ARCH=arm64 olddefconfig >/dev/null
grep -E "^CONFIG_MODULES=|^CONFIG_MODVERSIONS=|^CONFIG_KPROBES=|^CONFIG_CFI_CLANG" .config || true

echo "== 4. make prepare(只到能编外部模块为止) =="
# 设备的 config 是 clang 编的 ⇒ arch/arm64/Makefile 会加 -mlittle-endian，gcc 不认 ⇒ 必须 CC=clang
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=clang CC=clang -j"$(nproc)" prepare 2>&1 | tail -6
echo "PREPARE_OK(pipefail 保证上面失败就不会走到这里)"
