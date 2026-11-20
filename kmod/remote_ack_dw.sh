#!/bin/bash
# ACK 树（强制 LTO+CFI 留住的那份 config）的 DWARF 布局提取。
# 为什么和 remote_layout.sh 分开：ACK 的 per-task stackprotector flag 厂商 clang r383902b 不认，
# 但 Debian clang 14 认 —— 而**布局只由 config 决定，不由编译器决定**，所以这里用 CC=clang。
LOG=/home/lucy/ack_dw.log
exec > "$LOG" 2>&1
echo "START $(date)"
TREE=/root/k/ack
D=/root/k/layout_ack
cd "$TREE" || { echo NO_TREE; exit 1; }
echo "--- .config 布局敏感开关:"; grep -E '^CONFIG_(DEBUG_INFO|CFI|LTO|THINLTO|SCHEDSTATS|SCHED_DEBUG|MODVERSIONS|KPROBES|RANDSTRUCT|STACKPROTECTOR)' .config
echo "--- kernel.release: $(cat include/config/kernel.release)"
rm -rf "$D"; mkdir -p "$D"
cp /root/k/layout_linux-5.4.281/dw.c "$D/" 2>/dev/null || { echo "NO dw.c 模板"; exit 1; }
printf 'obj-m += dw.o\n' > "$D/Makefile"
TOOL="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip RANLIB=llvm-ranlib"
make $TOOL M="$D" modules 2>&1 | tail -10
if [ -f "$D/dw.o" ]; then
  OUT=/home/lucy/layout_ack.txt
  : > "$OUT"
  for S in task_struct cred module kprobe nsproxy thread_info signal_struct; do
    echo "===== $S (ack)" >> "$OUT"
    pahole -C "$S" "$D/dw.o" >> "$OUT" 2>&1
  done
  cp "$D/dw.o" /home/lucy/dw_ack.o
  echo "ACK_LAYOUT_OK $(wc -l < "$OUT") 行"
else
  echo "ACK_LAYOUT_FAIL"
fi
echo "END $(date)"
