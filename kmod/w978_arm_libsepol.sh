#!/bin/bash
# w978_arm_libsepol.sh — 0 枪：给设备交叉编一份 **arm64 静态 libsepol** ＋把 `w976` 那个"读→原样写"的往返件也编成交互式可执行文件。
#   为什么要这一步：§6.461 判定"空 delta 往返在语义上完全保真" ⇒ #216 不必先把 libsepol 打进 ko，
#   可以先做一个**设备上的小工具**：读 `/sys/fs/selinux/policy` → 只 insert 我要的几条 → 写出 patch → **自己跑差分自证**，
#   装载（写 `/sys/fs/selinux/load`）那一步**留给用户点头**，且只在 Permissive 段做。
#   ★本脚本只到"编出来＋在 x86 上验过往返"为止，不碰设备、不碰 load。
set -u
cd /home/lucy || exit 1
V=3.4
D=/home/lucy/sepolsrc
L=/home/lucy/armsepol
echo "S0 date=$(date -Is) 交叉链=$(command -v aarch64-linux-gnu-gcc) 静态 libc=$(ls /usr/lib/aarch64-linux-gnu/libc.a 2>/dev/null || echo 缺libc.a)"
if [ ! -d "$D/libsepol-$V" ]; then
  echo "S1 取上游 libsepol $V"
  curl -fsSL -o /home/lucy/libsepol-$V.tar.gz "https://github.com/SELinuxProject/selinux/releases/download/$V/libsepol-$V.tar.gz" 2>S1.err
  rc=$?
  if [ "$rc" != 0 ]; then echo "   下载失败 rc=$rc；err=$(head -2 S1.err)"; echo "   退路：直接用 Debian 的源码包 apt-get source libsepol"; exit 5; fi
  mkdir -p $D && tar xzf /home/lucy/libsepol-$V.tar.gz -C $D && echo "   解开：$(ls $D)"
else
  echo "S1 已有源码，跳过下载"
fi
cd $D/libsepol-$V || exit 5
echo "S2 编 arm64 版（只建 libsepol，禁 sepolgen/swig）"
make clean >/dev/null 2>&1
make -j3 CROSS_COMPILE=aarch64-linux-gnu- CFLAGS="-O2 -Wall -fPIC" LDFLAGS="" DISABLE_SEGOBJ_TOOLS=1 SWIG= NO_BSWAP=y 2>&1 | tail -6
ls -l src/libsepol.a src/libsepol.so* 2>&1 | head -3
file src/libsepol.a 2>/dev/null | cut -c1-90
echo "S3 用交叉 gcc 把 w976 编成 arm64 静态件（设备上没有 libsepol.so，必须静态）"
cd /home/lucy || exit 5
aarch64-linux-gnu-gcc -O2 -w w976_rt_public.c -o w976_arm \
   -I$D/libsepol-$V/include /home/lucy/armsepol.a 2>&1 | head -5
cp $D/libsepol-$V/src/libsepol.a /home/lucy/armsepol.a 2>/dev/null; ls -l /home/lucy/armsepol.a | head -1 $D/libsepol-$V/src/libsepol.a /home/lucy/armsepol.a
aarch64-linux-gnu-gcc -O2 -w w976_rt_public.c -static -o w976_arm \
   -I$D/libsepol-$V/include /home/lucy/armsepol.a 2>&1 | head -6
echo "   结果：$(file w976_arm 2>/dev/null | cut -c1-95)"
echo "S4 同时在 x86 上再跑一次往返，确认这棵树的行为与 §6.461 一致"
gcc -O2 -w w976_rt_public.c -o w976_x86 -I$D/libsepol-$V/include $D/libsepol-$V/src/libsepol.a 2>&1 | head -4
./w976_x86 /home/lucy/pol2/precompiled_sepolicy /home/lucy/pol2/rt2.bin 2>&1 | tr -cd '\11\12\40-\176' | tail -4
echo "SZ_END date=$(date -Is)  ★到这里为止：没推设备、没碰 load"
