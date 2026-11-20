#!/bin/bash
# build_ksuctl.sh —— 编 ksuctl(设备侧 aarch64 静态二进制)。
# ★为什么要有这份文件：少一个 flag 就得到一个"看着完全正常、上机第一句就 Aborted"的二进制。
#   第六十五发一手：本机 NDK r26b 默认对 `__thread` 走 **emulated TLS**，于是 .tdata 只有 8 字节对齐 ⇒
#   PT_TLS p_align=8 ⇒ Android 加载器直接拒：
#     `CANNOT LINK EXECUTABLE ... executable's TLS segment is underaligned: alignment is 8, needs to be at least 64 for ARM64 Bionic`
#   加 `-fno-emulated-tls` 之后 p_align=64(并且 vaddr%align == offset%align，加载器的同余检查也过)。
#   编完必须**自己验 PT_TLS**，不能只看"编译没报错"。
set -eu
cd "$(dirname "$0")/.." || exit 1
SRC=cm57/ksuctl.c
OUT=${1:-cm57/ksuctl88}
CC=ndk/android-ndk-r26b/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android21-clang
RE=ndk/android-ndk-r26b/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf
[ -x "$CC" ] || { echo "[x] 找不到 NDK clang: $CC"; exit 2; }
[ -f kmod/uapi/supercall.h ] || { echo "[x] 缺 kmod/uapi/supercall.h(源码里是 #include \"uapi/supercall.h\")"; exit 2; }
"$CC" -I kmod -O2 -static -fno-emulated-tls -o "$OUT" "$SRC"
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
        fs = struct.unpack_from('<Q', b, o + 32)[0]
        ms = struct.unpack_from('<Q', b, o + 40)[0]
        al = struct.unpack_from('<Q', b, o + 48)[0]
        hit = (al, va, off, fs, ms)
assert hit, "没有 PT_TLS(不该出现)"
al, va, off, fs, ms = hit
print(f"PT_TLS align={al} memsz={ms} vaddr%align={va % al} offset%align={off % al}")
assert al >= 64, f"!! align={al} < 64 ⇒ 上机必 Aborted(见本文件注释)"
assert va % al == off % al, "!! 同余检查不过 ⇒ 加载器会报 invalid alignment"
print("OK: 这条二进制能被 ARM64 Bionic 加载")
PY
"$RE" -S "$OUT" | grep -aiE "tbss|tdata" || true
md5sum "$OUT"
