#!/bin/bash
# build_sustatic.sh —— 编设备侧静态 su 壳(v4)。**默认输出到 cm57/sustatic_v4，不覆盖交付槽那份 sustatic**。
#   为什么单独有这份文件：`cm57/sustatic`(v3，md5 `f7a441d2…`，2,241,944 B)是**交付链上注册过的那支**，
#   而我不能证明今天这套 flag 能逐字重现它 ⇒ 任何"重编"都不许写到那个名字上
#   (一个名字只服务一个来源，例 110/113)。v4 只在 #117 那一格(实验形状)里被推上机。
#
# ★★API 档不是可选的装饰(10-18 19:2x 一手，靠真机抓出来的)：用 `aarch64-linux-android21-clang` 编出来的
#   这份 **PT_TLS p_align=8** ⇒ 设备加载器直接拒，运行只会看到
#     `error: "...": executable's TLS segment is underaligned: alignment is 8, needs to be at least 64 for ARM64 Bionic` + Aborted
#   换成 `aarch64-linux-android33-clang` 编同一份源码 ⇒ p_align=0x40(64)，与交付槽那支 v3 的 TLS 段**一样**(0x08/0x08/0x40)
#   ⇒ 这是"v3 大概也是 33 档编的"的**推断**(不是已证事实)，但"33 档这份能过加载器的同余检查"是硬读数。
#   ⇒ 所以本文件把 **align>=64 做成硬闸**，不看"编译没报错"(例 103：探针被拒不体现在 rc 上)。
set -eu
cd "$(dirname "$0")/.." || exit 1
SRC=cm57/su_static.c
OUT=${1:-cm57/sustatic_v4}
TOOL=ndk/android-ndk-r26b/toolchains/llvm/prebuilt/windows-x86_64/bin
CC=$TOOL/aarch64-linux-android33-clang
RE=$TOOL/llvm-readelf.exe
[ -x "$CC" ] || { echo "[x] 找不到 NDK clang: $CC"; exit 2; }
[ -f kmod/uapi/supercall.h ] || { echo "[x] 缺 kmod/uapi/supercall.h"; exit 2; }
echo "命令：$CC -I kmod -O2 -static -fno-emulated-tls -o $OUT $SRC"
"$CC" -I kmod -O2 -static -fno-emulated-tls -o "$OUT" "$SRC"
ls -l "$OUT" | tr -s ' ' | cut -d' ' -f5,9
md5sum "$OUT"

# --- 硬闸：PT_TLS 的 p_align 必须 >=64，且 vaddr%align == offset%align ---
PYTHONUTF8=1 python - "$OUT" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
phoff = struct.unpack_from('<Q', b, 0x20)[0]
phes = struct.unpack_from('<H', b, 0x36)[0]
phn = struct.unpack_from('<H', b, 0x38)[0]
hit = None
for i in range(phn):
    o = phoff + i * phes
    if struct.unpack_from('<I', b, o)[0] == 7:      # PT_TLS
        off = struct.unpack_from('<Q', b, o + 8)[0]
        va = struct.unpack_from('<Q', b, o + 16)[0]
        ms = struct.unpack_from('<Q', b, o + 40)[0]
        al = struct.unpack_from('<Q', b, o + 48)[0]
        hit = (al, va, off, ms)
assert hit, "没有 PT_TLS(这支不该没有)"
al, va, off, ms = hit
print("PT_TLS align=%d memsz=%d vaddr%%align=%d offset%%align=%d" % (al, ms, va % al, off % al))
assert al >= 64, "!! align=%d < 64 ⇒ 上机必被加载器拒(underaligned)，这支不许登记/上机" % al
assert va % al == off % al, "!! 同余不过 ⇒ 加载器同样会拒"
print("[OK] TLS 段对齐过闸(>=64 且同余一致)")
PY

# --- 幂等复证：连编两遍 md5 要相同，否则"来源"写不成事实 ---
TMP2="${OUT}.again"
"$CC" -I kmod -O2 -static -fno-emulated-tls -o "$TMP2" "$SRC"
A=$(md5sum "$OUT" | cut -c1-32); B=$(md5sum "$TMP2" | cut -c1-32)
rm -f "$TMP2"
if [ "$A" = "$B" ]; then echo "幂等复证 OK：连编两遍 md5 相同($A)"; else echo "[x] 连编两遍 md5 不同($A vs $B)⇒ 别登记"; exit 3; fi
echo "★真机回执另跑：adb push $OUT kmod/_tmp_selftest_rdst/probe_shbin.sh /data/local/tmp/ 然后 sh /data/local/tmp/probe_shbin.sh"
