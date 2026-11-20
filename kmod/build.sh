#!/bin/bash
# 手工造外部 .ko（不借内核构建树）。默认编阶段 0 探针 suwprobe。
#   bash build.sh            # = bash build.sh suwprobe
#   bash build.sh suwkprobe
# 产出 <名字>.ko，并跑 check_ko.py 的离线自检(自检不过就退出非 0，别上机)。
set -u
cd "$(dirname "$0")"
SDK="J:/Users/Administrator/AppData/Local/Android/Sdk"
BIN="$SDK/ndk/27.3.13750724/toolchains/llvm/prebuilt/windows-x86_64/bin"
CL="$BIN/aarch64-linux-android35-clang.cmd"
PY="C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe"
SYM=../analysis/Module.symvers_dev

SRC=${1:-suwprobe}
[ -f "$SRC.c" ] || { echo "[x] 没有 $SRC.c"; exit 1; }

# 这些 flag 每一条都有理由：
#   -ffreestanding/-nostdlib/-fno-builtin  内核里没有 libc，也不让 clang 把 printk 的调用改写成 memcpy 之类
#   -fno-pic -fno-pie -mcmodel=small       模块分配在 kernel text 附近的 module region，走 small 模型才不越界
#   -fno-stack-protector                   栈保护要 __stack_chk_fail，内核不提供
#   -ffixed-x18                            x18 在内核里是保留寄存器(SCS/shadow-call-stack)
#   -mgeneral-regs-only                    不许用 NEON(内核态不用 FPU/SIMD)
#   -fno-asynchronous-unwind-tables        少生成没用的 .eh_frame
CFLAGS="-target aarch64-linux-android -O2 -Wall -Wno-unused-function \
 -ffreestanding -nostdlib -fno-builtin -fno-pic -fno-pie -mcmodel=small \
 -fno-stack-protector -fno-asynchronous-unwind-tables -ffixed-x18 -mgeneral-regs-only"

echo "== 1. 编译 $SRC.c =="
"$CL" $CFLAGS -c "$SRC.c" -o "$SRC.o" || { echo "[x] 编译失败"; exit 1; }

echo "== 2. 链成可重定位 .ko (内核自己 apply_relocations) =="
"$BIN/ld.lld.exe" -r --build-id=none -o "$SRC.ko" "$SRC.o" || { echo "[x] 链接失败"; exit 1; }
ls -l "$SRC.ko"

echo "== 3. 离线自检(段/CRC/未定义引用) =="
"$PY" check_ko.py "$SRC.ko" "$SYM" || { echo "[x] 自检没过 —— 别上机"; exit 1; }
echo "DONE -> $SRC.ko"
