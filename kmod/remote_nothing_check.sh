#!/bin/bash
# 同 SoC 的第三方 qgki 树能不能逐字节复现设备的 struct 布局？
# 判据(全部来自真机实测)：struct module sizeof=960 / name@24 / init@392 / exit@888；
#                        offsetof(task_struct, cred) = 0x848 = 2120。
# 只要这几条对上，路线 B(真编 KSU)就不再需要 vivo 源码。
LOG=/home/lucy/nothing.log
exec > "$LOG" 2>&1
echo "START $(date)"
CL=/root/clangrepo/clang-r383902b/bin/clang
REPO=https://github.com/NothingOSS/android_kernel_msm-5.4_nothing_sm7325

echo "== 0. 分支清单 =="
git ls-remote --heads "$REPO" 2>&1 | awk '{print $2}' | sed 's|refs/heads/||' | head -20

for BR in "$@"; do
  TREE=/root/k/nothing_$(echo "$BR" | tr '/' '_')
  echo; echo "########## 分支 $BR ##########"
  if [ ! -d "$TREE/.git" ]; then
    git clone --depth 1 --single-branch -b "$BR" "$REPO" "$TREE" 2>&1 | tail -3 || { echo "CLONE_FAIL"; continue; }
  fi
  cd "$TREE" || continue
  echo "--- Makefile 版本:"; head -5 Makefile | grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL)'
  cp /root/k/config_dev.txt .config
  ./scripts/config --file .config --set-str LOCALVERSION "-qgki-g2a88cd145def" \
                   --disable LOCALVERSION_AUTO 2>/dev/null
  TOOL="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC=$CL"
  make $TOOL olddefconfig >/dev/null 2>&1
  echo "--- CFI/LTO 是否留住:"; grep -E '^CONFIG_CFI_CLANG|^CONFIG_LTO_CLANG|^CONFIG_THINLTO' .config
  make $TOOL -j"$(nproc)" prepare >/dev/null 2>&1 || { echo "PREPARE_FAIL"; continue; }
  echo "kernel.release = $(cat include/config/kernel.release 2>/dev/null)"
  cp /root/k/linux-5.4.281/Module.symvers ./Module.symvers

  M="$TREE/_abicheck"; mkdir -p "$M"; cp /home/lucy/abi_check.c "$M/"
  printf 'obj-m += abi_check.o\n' > "$M/Makefile"
  echo "--- 硬断言(不过会直接点名是哪一条):"
  make $TOOL M="$M" modules 2>&1 | grep -E "error:|abi_check.ko" | head -12
  [ -f "$M/abi_check.ko" ] && echo "ABI_MATCH=YES 分支 $BR" || echo "ABI_MATCH=NO 分支 $BR"

  D="$TREE/_abidump"; mkdir -p "$D"; cp /home/lucy/abi_dump2.c "$D/"
  printf 'obj-m += abi_dump2.o\n' > "$D/Makefile"
  echo "--- 实际数值(十进制；期望 cred=2120)："
  make $TOOL M="$D" modules 2>&1 | grep -oE "'char \(\*\)\[[0-9]+\]'" | head -8
  cd /root/k
done
echo "END $(date)"
echo "=== 日志尾部 ==="
tail -60 "$LOG"
