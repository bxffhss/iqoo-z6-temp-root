#!/usr/bin/env bash
# w1020_tiny_build.sh —— 在构建机上把 w1020_tiny.c 编成 .ko：与出货件同一棵树、同一条 make 行的编译器设置。
# 判据：①MAKE_RC=0 ②诊断 error/warning/implicit 三个=0 ③产物里有 __cfi_check ④打印 md5/尺寸给人核。
set -u
K=/root/k/nothing_sm7325_v_mr
D=/home/lucy/w1020
SRC=""
for c in "$PWD/w1020_tiny.c" "$HOME/w1020_tiny.c" /home/lucy/w1020_tiny.c /root/w1020_tiny.c; do [ -s "$c" ] && SRC="$c" && break; done
[ -n "$SRC" ] || { echo "!! 找不到上传上来的主源(w1020_tiny.c) ⇒ 停(不许凭记忆现写)"; exit 1; }
echo "主源=$SRC md5=$(md5sum \"$SRC\" | cut -c1-32)"
mkdir -p "$D" && cp "$SRC" "$D/" || exit 1
cat > "$D/Makefile" <<'MK'
obj-m += w1020_tiny.o
MK
cd "$D" || exit 1
LOG=$D/build.log
make -C "$K" M="$D" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld \
  AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-Wno-unused-function" > "$LOG" 2>&1
RC=$?; echo "MAKE_RC=$RC"
ERRN=$(grep -cE ': error: ' "$LOG"); WARNN=$(grep -cE ': warning: ' "$LOG"); IMPN=$(grep -cE 'implicit declaration' "$LOG")
echo "DIAG_ERR=$ERRN DIAG_WARN=$WARNN DIAG_IMPLICIT=$IMPN  (判据：三个都=0)"
[ "$RC" = 0 ] || { tail -20 "$LOG"; exit 1; }
[ -f "$D/w1020_tiny.ko" ] || { echo "!! 没有产物"; exit 1; }
CFIN=$(/usr/bin/llvm-nm "$D/w1020_tiny.ko" | grep -cw __cfi_check)
echo "  __cfi_check=$CFIN (必须=1)  未解析=$(llvm-nm -u $D/w1020_tiny.ko | wc -l)  重定位=$(llvm-readelf -r $D/w1020_tiny.ko 2>/dev/null | grep -c R_AARCH64)"
[ "$CFIN" = 1 ] || { echo "!! 没桩 ⇒ 不许上机"; exit 1; }
[ "$ERRN" = 0 ] && [ "$WARNN" = 0 ] && [ "$IMPN" = 0 ] || { echo "!! 诊断非零"; grep -E ': (warning|error): ' "$LOG" | sort -u | head; exit 1; }
ls -l "$D/w1020_tiny.ko" | tr -s ' ' | cut -d' ' -f5,9; md5sum "$D/w1020_tiny.ko"; echo "TINY_BUILD_OK"
