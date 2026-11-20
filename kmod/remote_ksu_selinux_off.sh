#!/bin/bash
# ③ 的最小验证：树里 struct selinux_state 的 disabled/enforcing 偏移，是否等于设备实测的 +0/+1。
# 手法沿用 §2 的 DWARF 路：文件作用域实例逼编译器 emit 整个结构体，再 pahole 读布局。
LOG=/home/lucy/ksu_selinux_off.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
D=$KDIR/_selprobe
rm -rf "$D"; mkdir -p "$D"
cat > "$D/sel_probe.c" <<'EOF'
#include <security.h>
/* 文件作用域实例 => 强制 emit struct selinux_state 的完整 DWARF */
struct selinux_state ksu_probe_state;
EOF
printf 'obj-m += sel_probe.o\n' > "$D/Makefile"
make -C "$KDIR" M="$D" CONFIG_KSU= ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy \
  KCFLAGS="-I$KDIR/security/selinux/include -I$KDIR/security/selinux" modules 2>&1 | tail -6
if [ -f "$D/sel_probe.o" ]; then
  echo "=== 树里的 struct selinux_state 前段布局 ==="
  pahole -C selinux_state "$D/sel_probe.o" | head -24
else
  echo "PROBE_FAIL"
fi
cat >> /home/lucy/ksu_selinux_off.log <<'X'
X
echo "END $(date)"
