#!/bin/bash
# 在远端用真 kbuild 编 kbuild_smoke.ko：塞进我们离线抽的 Module.symvers_dev，
# 并把版本串凑成设备那一串。产物拉回本地由 kmod/check_ko.py 判。
set -eo pipefail
TREE=/root/k/linux-5.4.281
M=/root/k/smoke

echo "== 1. 把离线 symvers 当成树的 Module.symvers(modpost 的 CRC 来源) =="
cp /home/lucy/Module.symvers_dev "$TREE/Module.symvers"
wc -l "$TREE/Module.symvers"

echo "== 2. 版本串凑成设备的 vermagic =="
cd "$TREE"
./scripts/config --file .config --set-str LOCALVERSION "-qgki-g2a88cd145def" \
                 --disable LOCALVERSION_AUTO
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=clang CC=clang prepare >/dev/null
echo "kernel.release = $(cat include/config/kernel.release)"

echo "== 3. 编模块 =="
mkdir -p "$M"
cp /home/lucy/kbuild_smoke.c "$M/"
printf 'obj-m += kbuild_smoke.o\n' > "$M/Makefile"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=clang CC=clang \
     M="$M" modules 2>&1 | tail -6
ls -l "$M/kbuild_smoke.ko"

echo "== 4. 段与 vermagic(本地 check_ko.py 会再判一遍) =="
aarch64-linux-gnu-readelf -S "$M/kbuild_smoke.ko" | grep -E "Name|__versions|modinfo|this_module|\.plt|trampoline" | head -8
strings "$M/kbuild_smoke.ko" | grep -E "^vermagic=" 
echo "SMOKE_OK"
