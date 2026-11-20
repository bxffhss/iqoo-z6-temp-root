#!/bin/bash
# 编 `abi_check2.ko`：全表硬断言 ⇒ 判"打了布局补丁的 QC 树 == 设备内存图"。
# 跑法(远端)：bash /home/lucy/remote_abi2.sh [pre]   pre=先看 dry-run 不真改
LOG=/home/lucy/abi2.log
exec > "$LOG" 2>&1
TREE=/root/k/nothing_sm7325_v_mr
echo "START $(date)"
cd "$TREE" || exit 1
echo "=== 0. 改前 git status(应当干净) ==="; git status --porcelain | head

echo; echo "=== 1. dry-run(锚点唯一性检查，不写文件) ==="
python3 /home/lucy/patch_device_layout.py "$TREE" --dry-run
[ -n "$1" ] && { echo "(只要 dry-run，结束)"; exit 0; }

echo; echo "=== 2. 打布局补丁 ==="
python3 /home/lucy/patch_device_layout.py "$TREE"
echo "--- 改了哪几行:"; git diff --stat

echo; echo "=== 3. 编 abi_check2(负长度数组断言：编不过会逐条点名) ==="
M="$TREE/_abi2"; rm -rf "$M"; mkdir -p "$M"
cp /home/lucy/abi_check2.c "$M/"
printf 'obj-m += abi_check2.o\n' > "$M/Makefile"
TOOL="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip RANLIB=llvm-ranlib"
make $TOOL M="$M" modules 2>&1 | tee /home/lucy/abi2_build_raw.log | tail -60
if [ -f "$M/abi_check2.ko" ]; then
  cp "$M/abi_check2.ko" /home/lucy/abi_check2.ko
  echo "ABI2_PASS —— 全表断言通过，这棵树(打完补丁)的布局 == 设备实测"
else
  echo "ABI2_FAIL —— 下面这些 chk_ 挂了(名字即哪条断言)"
  grep -oE "__chk_[a-z0-9_]+" /home/lucy/abi2_build_raw.log | sort -u
fi
echo "END $(date)"
