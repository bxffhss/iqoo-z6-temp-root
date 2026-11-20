#!/bin/bash
# build_policeprobe.sh —— 编 #77 的探针(aarch64 静态)。规矩与 ksuctl 一样：
#   少 -fno-emulated-tls 就得到"看着正常、上机第一句 Aborted(TLS segment is underaligned)"的二进制，
#   所以编完必须自己验 PT_TLS(与 cm57/build_ksuctl.sh 同一套自检)。
set -eu
cd "$(dirname "$0")/.." || exit 1
SRC=cm57/policeprobe.c
OUT=${1:-cm57/policeprobe}
CC=ndk/android-ndk-r26b/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android21-clang
RE=ndk/android-ndk-r26b/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf
[ -x "$CC" ] || { echo "[x] 找不到 NDK clang: $CC"; exit 2; }
[ -f "$SRC" ] || { echo "[x] 没有 $SRC"; exit 2; }
"$CC" -O2 -static -fno-emulated-tls -Wall -o "$OUT" "$SRC"
python - "$OUT" <<'PY'
import struct, sys
p = sys.argv[1]
b = open(p, 'rb').read()
phoff = struct.unpack_from('<Q', b, 0x20)[0]
phes = struct.unpack_from('<H', b, 0x36)[0]
phn = struct.unpack_from('<H', b, 0x38)[0]
hit = None
for i in range(phn):
    o = phoff + i * phes
    if struct.unpack_from('<I', b, o)[0] == 7:  # PT_TLS
        off = struct.unpack_from('<Q', b, o + 8)[0]
        va = struct.unpack_from('<Q', b, o + 16)[0]
        al = struct.unpack_from('<Q', b, o + 48)[0]
        ms = struct.unpack_from('<Q', b, o + 40)[0]
        hit = (al, va, off, ms)
assert hit, "没有 PT_TLS(不该出现)"
al, va, off, ms = hit
print(f"PT_TLS align={al} memsz={ms} vaddr%align={va % al} offset%align={off % al}")
# ★#77 一手(我把这条断言松掉过一次，当场被设备打回)：align 不是恒定 64 —— 只用 errno 的探针
#   TLS 块是 8 字节，p_align 也就 8，而 ARM64 Bionic 加载器**无条件要求 >= 64**，
#   报错原文 `executable's TLS segment is underaligned: alignment is 8, needs to be at least 64` ⇒ SIGABRT(rc=134)。
#   "同余过了"不等于能加载；同余是另一个坑，两条都要判。⇒ 断言装回来，源码里放 aligned(64) 的 __thread 变量。
assert al >= 64, f"!! align={al} < 64 ⇒ Bionic 加载器直接 Aborted(本发实测)"
assert va % al == off % al, "!! 同余检查不过 ⇒ 加载器会报 invalid alignment"
print("OK: 这条二进制能被 ARM64 Bionic 加载")
PY
md5sum "$OUT"
